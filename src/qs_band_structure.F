!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Calculation of band structures
!> \par History
!>       2015.06 created [JGH]
!> \author JGH
! **************************************************************************************************
MODULE qs_band_structure
   USE cell_types,                      ONLY: cell_type
   USE cp_blacs_env,                    ONLY: cp_blacs_env_retain,&
                                              cp_blacs_env_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_log_handling,                 ONLY: cp_logger_get_default_io_unit
   USE cp_para_env,                     ONLY: cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_parser_methods,               ONLY: read_float_object
   USE dbcsr_api,                       ONLY: dbcsr_p_type
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_string_length,&
                                              dp,&
                                              max_line_length
   USE kpoint_methods,                  ONLY: kpoint_env_initialize,&
                                              kpoint_init_cell_index,&
                                              kpoint_initialize_mo_set,&
                                              kpoint_initialize_mos
   USE kpoint_types,                    ONLY: get_kpoint_info,&
                                              kpoint_create,&
                                              kpoint_env_type,&
                                              kpoint_release,&
                                              kpoint_sym_create,&
                                              kpoint_type
   USE machine,                         ONLY: m_walltime
   USE mathconstants,                   ONLY: twopi
   USE message_passing,                 ONLY: mp_sum
   USE physcon,                         ONLY: angstrom,&
                                              evolt
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_env_release,&
                                              qs_environment_type
   USE qs_gamma2kp,                     ONLY: create_kp_from_gamma
   USE qs_mo_types,                     ONLY: get_mo_set
   USE qs_neighbor_list_types,          ONLY: neighbor_list_set_p_type
   USE qs_scf_diagonalization,          ONLY: do_general_diag_kp
   USE qs_scf_types,                    ONLY: qs_scf_env_type
   USE scf_control_types,               ONLY: scf_control_type
   USE string_utilities,                ONLY: uppercase
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_band_structure'

   PUBLIC :: calculate_band_structure, calculate_kp_orbitals, calculate_kpoints_for_bs

! **************************************************************************************************

CONTAINS

! **************************************************************************************************
!> \brief Main routine for band structure calculation
!> \param qs_env ...
!> \author JGH
! **************************************************************************************************
   SUBROUTINE calculate_band_structure(qs_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env

      LOGICAL                                            :: do_kpoints, explicit
      TYPE(section_vals_type), POINTER                   :: bs_input

      bs_input => section_vals_get_subs_vals(qs_env%input, "DFT%PRINT%BAND_STRUCTURE")
      CALL section_vals_get(bs_input, explicit=explicit)
      IF (explicit) THEN
         CALL get_qs_env(qs_env, do_kpoints=do_kpoints)
         IF (do_kpoints) THEN
            CALL do_calculate_band_structure(qs_env)
         ELSE
            BLOCK
               TYPE(qs_environment_type), POINTER :: qs_env_kp
               CALL create_kp_from_gamma(qs_env, qs_env_kp)
               CALL do_calculate_band_structure(qs_env_kp)
               CALL qs_env_release(qs_env_kp)
               DEALLOCATE (qs_env_kp)
            END BLOCK
         END IF
      END IF

   END SUBROUTINE calculate_band_structure

! **************************************************************************************************
!> \brief band structure calculation
!> \param qs_env ...
!> \author JGH
! **************************************************************************************************
   SUBROUTINE do_calculate_band_structure(qs_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(LEN=default_string_length)               :: filename, ustr
      CHARACTER(LEN=default_string_length), &
         DIMENSION(:), POINTER                           :: spname, strptr
      CHARACTER(LEN=max_line_length)                     :: error_message
      INTEGER                                            :: bs_data_unit, i, i_rep, ik, ikk, ikpgr, &
                                                            imo, ip, ispin, n_ptr, n_rep, nadd, &
                                                            nkp, nmo, npline, npoints, nspins, &
                                                            unit_nr
      INTEGER, DIMENSION(2)                              :: kp_range
      LOGICAL                                            :: explicit, io_default, my_kpgrp
      REAL(KIND=dp)                                      :: t1, t2
      REAL(KIND=dp), DIMENSION(3)                        :: kpptr
      REAL(KIND=dp), DIMENSION(:), POINTER               :: eigenvalues, eigval, occnum, &
                                                            occupation_numbers, wkp
      REAL(kind=dp), DIMENSION(:, :), POINTER            :: kpgeneral, kspecial, xkp
      TYPE(cell_type), POINTER                           :: cell
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(kpoint_env_type), POINTER                     :: kp
      TYPE(kpoint_type), POINTER                         :: kpoint
      TYPE(section_vals_type), POINTER                   :: bs_input, kpset

      bs_input => section_vals_get_subs_vals(qs_env%input, "DFT%PRINT%BAND_STRUCTURE")
      CALL section_vals_get(bs_input, explicit=explicit)
      IF (explicit) THEN
         CALL section_vals_val_get(bs_input, "FILE_NAME", c_val=filename)
         CALL section_vals_val_get(bs_input, "ADDED_MOS", i_val=nadd)
         unit_nr = cp_logger_get_default_io_unit()
         CALL get_qs_env(qs_env=qs_env, para_env=para_env)
         CALL get_qs_env(qs_env, cell=cell)
         kpset => section_vals_get_subs_vals(bs_input, "KPOINT_SET")
         CALL section_vals_get(kpset, n_repetition=n_rep)
         IF (unit_nr > 0) THEN
            WRITE (unit_nr, FMT="(/,T2,A)") "KPOINTS| Band Structure Calculation"
            WRITE (unit_nr, FMT="(T2,A,T71,I10)") "KPOINTS| Number of k-point sets", n_rep
            IF (nadd /= 0) THEN
               WRITE (unit_nr, FMT="(T2,A,T71,I10)") "KPOINTS| Number of added MOs/bands", nadd
            END IF
         END IF
         IF (filename == "") THEN
            ! use standard output file
            bs_data_unit = unit_nr
            io_default = .TRUE.
         ELSE
            io_default = .FALSE.
            IF (para_env%ionode) THEN
               CALL open_file(filename, unit_number=bs_data_unit, file_status="UNKNOWN", file_action="WRITE", &
                              file_position="APPEND")
            ELSE
               bs_data_unit = -1
            END IF
         END IF
         DO i_rep = 1, n_rep
            t1 = m_walltime()
            CALL section_vals_val_get(kpset, "NPOINTS", i_rep_section=i_rep, i_val=npline)
            CALL section_vals_val_get(kpset, "UNITS", i_rep_section=i_rep, c_val=ustr)
            CALL uppercase(ustr)
            CALL section_vals_val_get(kpset, "SPECIAL_POINT", i_rep_section=i_rep, n_rep_val=n_ptr)
            ALLOCATE (kspecial(3, n_ptr))
            ALLOCATE (spname(n_ptr))
            DO ip = 1, n_ptr
               CALL section_vals_val_get(kpset, "SPECIAL_POINT", i_rep_section=i_rep, i_rep_val=ip, c_vals=strptr)
               IF (SIZE(strptr(:), 1) == 4) THEN
                  spname(ip) = strptr(1)
                  DO i = 1, 3
                     CALL read_float_object(strptr(i + 1), kpptr(i), error_message)
                     IF (LEN_TRIM(error_message) > 0) CPABORT(TRIM(error_message))
                  END DO
               ELSE IF (SIZE(strptr(:), 1) == 3) THEN
                  spname(ip) = "not specified"
                  DO i = 1, 3
                     CALL read_float_object(strptr(i), kpptr(i), error_message)
                     IF (LEN_TRIM(error_message) > 0) CPABORT(TRIM(error_message))
                  END DO
               ELSE
                  CPABORT("Input SPECIAL_POINT invalid")
               END IF
               SELECT CASE (ustr)
               CASE ("B_VECTOR")
                  kspecial(1:3, ip) = kpptr(1:3)
               CASE ("CART_ANGSTROM")
                  kspecial(1:3, ip) = (kpptr(1)*cell%hmat(1, 1:3) + &
                                       kpptr(2)*cell%hmat(2, 1:3) + &
                                       kpptr(3)*cell%hmat(3, 1:3))/twopi*angstrom
               CASE ("CART_BOHR")
                  kspecial(1:3, ip) = (kpptr(1)*cell%hmat(1, 1:3) + &
                                       kpptr(2)*cell%hmat(2, 1:3) + &
                                       kpptr(3)*cell%hmat(3, 1:3))/twopi
               CASE DEFAULT
                  CPABORT("Unknown unit <"//TRIM(ustr)//"> specified for k-point definition")
               END SELECT
            END DO
            npoints = (n_ptr - 1)*npline + 1
            CPASSERT(npoints >= 1)

            ! Initialize environment and calculate MOs
            ALLOCATE (kpgeneral(3, npoints))
            kpgeneral(1:3, 1) = kspecial(1:3, 1)
            ikk = 1
            DO ik = 2, n_ptr
               DO ip = 1, npline
                  ikk = ikk + 1
                  kpgeneral(1:3, ikk) = kspecial(1:3, ik - 1) + &
                                        REAL(ip, KIND=dp)/REAL(npline, KIND=dp)* &
                                        (kspecial(1:3, ik) - kspecial(1:3, ik - 1))
               END DO
            END DO
            NULLIFY (kpoint)
            CALL calculate_kp_orbitals(qs_env, kpoint, "GENERAL", nadd, kpgeneral=kpgeneral)
            DEALLOCATE (kpgeneral)

            CALL get_qs_env(qs_env, dft_control=dft_control)
            nspins = dft_control%nspins
            kp => kpoint%kp_env(1)%kpoint_env
            CALL get_mo_set(kp%mos(1, 1), nmo=nmo)
            ALLOCATE (eigval(nmo), occnum(nmo))
            CALL get_kpoint_info(kpoint, nkp=nkp, kp_range=kp_range, xkp=xkp, wkp=wkp)

            IF (unit_nr > 0) THEN
               WRITE (UNIT=unit_nr, FMT="(T2,A,I4,T71,I10)") &
                  "KPOINTS| Number of k-points in set ", i_rep, npoints
               WRITE (UNIT=unit_nr, FMT="(T2,A)") &
                  "KPOINTS| In units of b-vector [2pi/Bohr]"
               DO ip = 1, n_ptr
                  WRITE (UNIT=unit_nr, FMT="(T2,A,I5,1X,A11,3(1X,F12.6))") &
                     "KPOINTS| Special point ", ip, ADJUSTL(TRIM(spname(ip))), kspecial(1:3, ip)
               END DO
            END IF
            IF (bs_data_unit > 0 .AND. (bs_data_unit /= unit_nr)) THEN
               WRITE (UNIT=bs_data_unit, FMT="(4(A,I0),A)") &
                  "# Set ", i_rep, ": ", n_ptr, " special points, ", npoints, " k-points, ", nmo, " bands"
               DO ip = 1, n_ptr
                  WRITE (UNIT=bs_data_unit, FMT="(A,I0,T20,T24,3(1X,F14.8),2X,A)") &
                     "#  Special point ", ip, kspecial(1:3, ip), ADJUSTL(TRIM(spname(ip)))
               END DO
            END IF

            DO ik = 1, nkp
               my_kpgrp = (ik >= kp_range(1) .AND. ik <= kp_range(2))
               DO ispin = 1, nspins
                  IF (my_kpgrp) THEN
                     ikpgr = ik - kp_range(1) + 1
                     kp => kpoint%kp_env(ikpgr)%kpoint_env
                     CALL get_mo_set(kp%mos(1, ispin), eigenvalues=eigenvalues, occupation_numbers=occupation_numbers)
                     eigval(1:nmo) = eigenvalues(1:nmo)
                     occnum(1:nmo) = occupation_numbers(1:nmo)
                  ELSE
                     eigval(1:nmo) = 0.0_dp
                     occnum(1:nmo) = 0.0_dp
                  END IF
                  CALL mp_sum(eigval, kpoint%para_env_inter_kp%group)
                  CALL mp_sum(occnum, kpoint%para_env_inter_kp%group)
                  IF (bs_data_unit > 0) THEN
                     WRITE (UNIT=bs_data_unit, FMT="(A,I0,T15,A,I0,A,T24,3(1X,F14.8),3X,F14.8)") &
                        "#  Point ", ik, "  Spin ", ispin, ":", xkp(1:3, ik), wkp(ik)
                     WRITE (UNIT=bs_data_unit, FMT="(A)") &
                        "#   Band    Energy [eV]     Occupation"
                     DO imo = 1, nmo
                        WRITE (UNIT=bs_data_unit, FMT="(T2,I7,2(1X,F14.8))") &
                           imo, eigval(imo)*evolt, occnum(imo)
                     END DO
                  END IF
               END DO
            END DO

            DEALLOCATE (kspecial, spname)
            DEALLOCATE (eigval, occnum)
            CALL kpoint_release(kpoint)
            t2 = m_walltime()
            IF (unit_nr > 0) THEN
               WRITE (UNIT=unit_nr, FMT="(T2,A,T67,F14.3)") "KPOINTS| Time for k-point line ", t2 - t1
            END IF

         END DO

         ! Close output files
         IF (.NOT. io_default) THEN
            IF (para_env%ionode) CALL close_file(bs_data_unit)
         END IF

      END IF

   END SUBROUTINE do_calculate_band_structure

! **************************************************************************************************
!> \brief diagonalize KS matrices at a set of kpoints
!> \param qs_env ...
!> \param kpoint ...
!> \param scheme ...
!> \param nadd ...
!> \param mp_grid ...
!> \param kpgeneral ...
!> \param group_size_ext ...
!> \author JGH
! **************************************************************************************************
   SUBROUTINE calculate_kp_orbitals(qs_env, kpoint, scheme, nadd, mp_grid, kpgeneral, group_size_ext)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(kpoint_type), POINTER                         :: kpoint
      CHARACTER(LEN=*), INTENT(IN)                       :: scheme
      INTEGER, INTENT(IN)                                :: nadd
      INTEGER, DIMENSION(3), INTENT(IN), OPTIONAL        :: mp_grid
      REAL(KIND=dp), DIMENSION(:, :), INTENT(IN), &
         OPTIONAL                                        :: kpgeneral
      INTEGER, INTENT(IN), OPTIONAL                      :: group_size_ext

      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_ks, matrix_s
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_nl
      TYPE(qs_scf_env_type), POINTER                     :: scf_env
      TYPE(scf_control_type), POINTER                    :: scf_control

      CALL calculate_kpoints_for_bs(kpoint, scheme, group_size_ext, mp_grid, kpgeneral)

      CALL get_qs_env(qs_env=qs_env, para_env=para_env, blacs_env=blacs_env)
      kpoint%para_env => para_env
      CALL cp_para_env_retain(para_env)
      kpoint%blacs_env_all => blacs_env
      CALL cp_blacs_env_retain(blacs_env)
      CALL kpoint_env_initialize(kpoint)

      CALL kpoint_initialize_mos(kpoint, qs_env%mos, nadd)
      CALL kpoint_initialize_mo_set(kpoint)

      CALL get_qs_env(qs_env, sab_kp=sab_nl, dft_control=dft_control)
      CALL kpoint_init_cell_index(kpoint, sab_nl, para_env, dft_control)

      CALL get_qs_env(qs_env, matrix_ks_kp=matrix_ks, matrix_s_kp=matrix_s, &
                      scf_env=scf_env, scf_control=scf_control)
      CALL do_general_diag_kp(matrix_ks, matrix_s, kpoint, scf_env, scf_control, .FALSE.)

   END SUBROUTINE calculate_kp_orbitals

! **************************************************************************************************
!> \brief ...
!> \param kpoint ...
!> \param scheme ...
!> \param group_size_ext ...
!> \param mp_grid ...
!> \param kpgeneral ...
! **************************************************************************************************
   SUBROUTINE calculate_kpoints_for_bs(kpoint, scheme, group_size_ext, mp_grid, kpgeneral)

      TYPE(kpoint_type), POINTER                         :: kpoint
      CHARACTER(LEN=*), INTENT(IN)                       :: scheme
      INTEGER, INTENT(IN), OPTIONAL                      :: group_size_ext
      INTEGER, DIMENSION(3), INTENT(IN), OPTIONAL        :: mp_grid
      REAL(KIND=dp), DIMENSION(:, :), INTENT(IN), &
         OPTIONAL                                        :: kpgeneral

      INTEGER                                            :: i, ix, iy, iz, npoints

      CPASSERT(.NOT. ASSOCIATED(kpoint))

      CALL kpoint_create(kpoint)

      kpoint%kp_scheme = scheme
      kpoint%symmetry = .FALSE.
      kpoint%verbose = .FALSE.
      kpoint%full_grid = .FALSE.
      kpoint%use_real_wfn = .FALSE.
      kpoint%eps_geo = 1.e-6_dp
      IF (PRESENT(group_size_ext)) THEN
         kpoint%parallel_group_size = group_size_ext
      ELSE
         kpoint%parallel_group_size = -1
      END IF
      SELECT CASE (scheme)
      CASE ("GAMMA")
         kpoint%nkp = 1
         ALLOCATE (kpoint%xkp(3, 1), kpoint%wkp(1))
         kpoint%xkp(1:3, 1) = 0.0_dp
         kpoint%wkp(1) = 1.0_dp
         kpoint%symmetry = .TRUE.
         ALLOCATE (kpoint%kp_sym(1))
         NULLIFY (kpoint%kp_sym(1)%kpoint_sym)
         CALL kpoint_sym_create(kpoint%kp_sym(1)%kpoint_sym)
      CASE ("MONKHORST-PACK")
         CPASSERT(PRESENT(mp_grid))
         npoints = mp_grid(1)*mp_grid(2)*mp_grid(3)
         kpoint%nkp_grid(1:3) = mp_grid(1:3)
         kpoint%full_grid = .TRUE.
         kpoint%nkp = npoints
         ALLOCATE (kpoint%xkp(3, npoints), kpoint%wkp(npoints))
         kpoint%wkp(:) = 1._dp/REAL(npoints, KIND=dp)
         i = 0
         DO ix = 1, mp_grid(1)
            DO iy = 1, mp_grid(2)
               DO iz = 1, mp_grid(3)
                  i = i + 1
                  kpoint%xkp(1, i) = REAL(2*ix - mp_grid(1) - 1, KIND=dp)/(2._dp*REAL(mp_grid(1), KIND=dp))
                  kpoint%xkp(2, i) = REAL(2*iy - mp_grid(2) - 1, KIND=dp)/(2._dp*REAL(mp_grid(2), KIND=dp))
                  kpoint%xkp(3, i) = REAL(2*iz - mp_grid(3) - 1, KIND=dp)/(2._dp*REAL(mp_grid(3), KIND=dp))
               END DO
            END DO
         END DO
         ! default: no symmetry settings
         ALLOCATE (kpoint%kp_sym(kpoint%nkp))
         DO i = 1, kpoint%nkp
            NULLIFY (kpoint%kp_sym(i)%kpoint_sym)
            CALL kpoint_sym_create(kpoint%kp_sym(i)%kpoint_sym)
         END DO
      CASE ("MACDONALD")
         CPABORT("MACDONALD not implemented")
      CASE ("GENERAL")
         CPASSERT(PRESENT(kpgeneral))
         npoints = SIZE(kpgeneral, 2)
         kpoint%nkp = npoints
         ALLOCATE (kpoint%xkp(3, npoints), kpoint%wkp(npoints))
         kpoint%wkp(:) = 1._dp/REAL(npoints, KIND=dp)
         kpoint%xkp(1:3, 1:npoints) = kpgeneral(1:3, 1:npoints)
         ! default: no symmetry settings
         ALLOCATE (kpoint%kp_sym(kpoint%nkp))
         DO i = 1, kpoint%nkp
            NULLIFY (kpoint%kp_sym(i)%kpoint_sym)
            CALL kpoint_sym_create(kpoint%kp_sym(i)%kpoint_sym)
         END DO
      CASE DEFAULT
         CPABORT("Unknown kpoint scheme requested")
      END SELECT

   END SUBROUTINE calculate_kpoints_for_bs

END MODULE qs_band_structure
