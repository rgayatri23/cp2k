!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Initialize the XAS orbitals for specific core excitations
!>       Either the GS orbitals are used as initial guess, or the
!>       xas mos are read from a previous calculation.
!>       In the latter case, the core-hole potetial should be the same.
!> \note
!>       The restart with the same core-hole potential should be checked
!>       and a wrong restart should stop the program
!> \par History
!>      created 09.2006
!> \author MI (09.2006)
! **************************************************************************************************
MODULE xas_restart

   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_operations,             ONLY: cp_dbcsr_sm_fm_multiply
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_get_submatrix,&
                                              cp_fm_release,&
                                              cp_fm_set_all,&
                                              cp_fm_set_submatrix,&
                                              cp_fm_type,&
                                              cp_fm_write_unformatted
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type,&
                                              cp_to_string
   USE cp_output_handling,              ONLY: cp_p_file,&
                                              cp_print_key_finished_output,&
                                              cp_print_key_generate_filename,&
                                              cp_print_key_should_output,&
                                              cp_print_key_unit_nr
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_p_type
   USE input_section_types,             ONLY: section_vals_type
   USE kinds,                           ONLY: default_path_length,&
                                              default_string_length,&
                                              dp
   USE message_passing,                 ONLY: mp_bcast,&
                                              mp_comm_type
   USE parallel_gemm_api,               ONLY: parallel_gemm
   USE particle_types,                  ONLY: particle_type
   USE qs_density_matrices,             ONLY: calculate_density_matrix
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_kind_types,                   ONLY: qs_kind_type
   USE qs_ks_types,                     ONLY: qs_ks_did_change
   USE qs_mixing_utils,                 ONLY: mixing_init
   USE qs_mo_io,                        ONLY: wfn_restart_file_name,&
                                              write_mo_set_low
   USE qs_mo_occupation,                ONLY: set_mo_occupation
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_type,&
                                              set_mo_set
   USE qs_rho_atom_types,               ONLY: rho_atom_type
   USE qs_rho_methods,                  ONLY: qs_rho_update_rho
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE qs_scf_types,                    ONLY: qs_scf_env_type
   USE scf_control_types,               ONLY: scf_control_type
   USE string_utilities,                ONLY: xstring
   USE xas_env_types,                   ONLY: get_xas_env,&
                                              set_xas_env,&
                                              xas_environment_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'xas_restart'

! *** Public subroutines ***

   PUBLIC ::  xas_read_restart, xas_write_restart, xas_initialize_rho, find_excited_core_orbital

CONTAINS

! **************************************************************************************************
!> \brief Set up for reading the restart
!>      corresponding to the excitation of iatom
!>      If the corresponding restart file does not exist
!>      the GS orbitals are used as initial guess
!> \param xas_env ...
!> \param xas_section input section for XAS calculations
!>      qs_env:
!> \param qs_env ...
!> \param xas_method ...
!> \param iatom index of the absorbing atom
!> \param estate index of the core-hole orbital
!> \param istate counter of excited states per atom
!>      error:
!> \par History
!>      09.2006 created [MI]
!> \author MI
! **************************************************************************************************
   SUBROUTINE xas_read_restart(xas_env, xas_section, qs_env, xas_method, iatom, estate, istate)

      TYPE(xas_environment_type), POINTER                :: xas_env
      TYPE(section_vals_type), POINTER                   :: xas_section
      TYPE(qs_environment_type), POINTER                 :: qs_env
      INTEGER, INTENT(IN)                                :: xas_method, iatom
      INTEGER, INTENT(OUT)                               :: estate
      INTEGER, INTENT(IN)                                :: istate

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'xas_read_restart'

      CHARACTER(LEN=default_path_length)                 :: filename
      INTEGER :: handle, i, ia, ie, ispin, my_spin, nao, nao_read, nelectron, nexc_atoms, &
         nexc_atoms_read, nexc_search, nexc_search_read, nmo, nmo_read, output_unit, rst_unit, &
         source, xas_estate, xas_estate_read, xas_method_read
      LOGICAL                                            :: file_exists
      REAL(dp)                                           :: occ_estate, occ_estate_read, &
                                                            xas_nelectron, xas_nelectron_read
      REAL(dp), DIMENSION(:), POINTER                    :: eigenvalues, occupation_numbers
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: eig_read, occ_read
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: vecbuffer
      TYPE(cp_fm_type), POINTER                          :: mo_coeff
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(mp_comm_type)                                 :: group

      CALL timeset(routineN, handle)

      file_exists = .FALSE.
      rst_unit = -1

      NULLIFY (eigenvalues, matrix_s, mos, occupation_numbers, vecbuffer)
      NULLIFY (logger)
      logger => cp_get_default_logger()

      output_unit = cp_print_key_unit_nr(logger, xas_section, &
                                         "PRINT%PROGRAM_RUN_INFO", extension=".Log")

      CALL get_qs_env(qs_env=qs_env, para_env=para_env)
      group = para_env%group
      source = para_env%source

      IF (para_env%ionode) THEN
         CALL wfn_restart_file_name(filename, file_exists, xas_section, logger, &
                                    xas=.TRUE.)

         CALL xstring(filename, ia, ie)
         filename = filename(ia:ie)//'-at'//TRIM(ADJUSTL(cp_to_string(iatom)))// &
                    '_st'//TRIM(ADJUSTL(cp_to_string(istate)))//'.rst'

         INQUIRE (FILE=filename, EXIST=file_exists)
         ! open file
         IF (file_exists) THEN

            CALL open_file(file_name=TRIM(filename), &
                           file_action="READ", &
                           file_form="UNFORMATTED", &
                           file_position="REWIND", &
                           file_status="OLD", &
                           unit_number=rst_unit)

            IF (output_unit > 0) WRITE (UNIT=output_unit, FMT="(/,T20,A,I5,/)") &
               "Read restart file for atom ", iatom

         ELSE IF (.NOT. file_exists) THEN
            IF (output_unit > 0) WRITE (UNIT=output_unit, FMT="(/,T10,A,I5,A,/)") &
               "Restart file for atom ", iatom, &
               " not available. Initialization done with GS orbitals"
         END IF
      END IF
      CALL mp_bcast(file_exists, source, group)

      CALL get_xas_env(xas_env=xas_env, occ_estate=occ_estate, xas_estate=xas_estate, &
                       xas_nelectron=xas_nelectron, nexc_search=nexc_search, &
                       nexc_atoms=nexc_atoms, spin_channel=my_spin)

      IF (file_exists) THEN
         CALL get_qs_env(qs_env=qs_env, mos=mos, matrix_s=matrix_s)

         IF (rst_unit > 0) THEN
            READ (rst_unit) xas_method_read
            READ (rst_unit) nexc_search_read, nexc_atoms_read, occ_estate_read, xas_nelectron_read
            READ (rst_unit) xas_estate_read

            IF (xas_method_read /= xas_method) &
               CPABORT(" READ XAS RESTART: restart with different XAS method is not possible. ")
            IF (nexc_atoms_read /= nexc_atoms) &
               CALL cp_abort(__LOCATION__, &
                             " READ XAS RESTART: restart with different excited atoms "// &
                             " is not possible. Start instead a new XAS run with the new set of atoms. ")
         END IF

         CALL mp_bcast(xas_estate_read, source, group)
         CALL set_xas_env(xas_env=xas_env, xas_estate=xas_estate_read)
         estate = xas_estate_read

         CALL get_mo_set(mo_set=mos(my_spin), nao=nao)
         ALLOCATE (vecbuffer(1, nao))

         DO ispin = 1, SIZE(mos)
            CALL get_mo_set(mo_set=mos(ispin), nmo=nmo, eigenvalues=eigenvalues, &
                            occupation_numbers=occupation_numbers, mo_coeff=mo_coeff, nelectron=nelectron)
            eigenvalues = 0.0_dp
            occupation_numbers = 0.0_dp
            CALL cp_fm_set_all(mo_coeff, 0.0_dp)
            IF (para_env%ionode) THEN
               READ (rst_unit) nao_read, nmo_read
               IF (nao /= nao_read) &
                  CPABORT("To change basis is not possible. ")
               ALLOCATE (eig_read(nmo_read), occ_read(nmo_read))
               eig_read = 0.0_dp
               occ_read = 0.0_dp
               nmo = MIN(nmo, nmo_read)
               READ (rst_unit) eig_read(1:nmo_read), occ_read(1:nmo_read)
               eigenvalues(1:nmo) = eig_read(1:nmo)
               occupation_numbers(1:nmo) = occ_read(1:nmo)
               IF (nmo_read > nmo) THEN
                  IF (occupation_numbers(nmo) >= EPSILON(0.0_dp)) &
                     CALL cp_warn(__LOCATION__, &
                                  "The number of occupied MOs on the restart unit is larger than "// &
                                  "the allocated MOs.")

               END IF
               DEALLOCATE (eig_read, occ_read)
            END IF
            CALL mp_bcast(eigenvalues, source, group)
            CALL mp_bcast(occupation_numbers, source, group)

            DO i = 1, nmo
               IF (para_env%ionode) THEN
                  READ (rst_unit) vecbuffer
               ELSE
                  vecbuffer(1, :) = 0.0_dp
               END IF
               CALL mp_bcast(vecbuffer, source, group)
               CALL cp_fm_set_submatrix(mo_coeff, &
                                        vecbuffer, 1, i, nao, 1, transpose=.TRUE.)
            END DO
            ! Skip extra MOs if there any
            IF (para_env%ionode) THEN
               DO i = nmo + 1, nmo_read
                  READ (rst_unit) vecbuffer
               END DO
            END IF

         END DO ! ispin

         DEALLOCATE (vecbuffer)

!      nspin = SIZE(mos,1)
!      DO ispin = 1,nspin
!      ! ortho so that one can restart for different positions (basis sets?)
!         NULLIFY(mo_coeff)
!         CALL get_mo_set(mo_set=mos(ispin), mo_coeff=mo_coeff,homo=homo)
!         CALL make_basis_sm(mo_coeff,homo,matrix_s(1)%matrix)
!      END DO
      END IF !file_exist

      IF (para_env%ionode) THEN
         IF (file_exists) CALL close_file(unit_number=rst_unit)
      END IF

      CALL timestop(handle)

   END SUBROUTINE xas_read_restart

! **************************************************************************************************
!> \brief ...
!> \param xas_env ...
!> \param xas_section ...
!> \param qs_env ...
!> \param xas_method ...
!> \param iatom ...
!> \param istate ...
! **************************************************************************************************
   SUBROUTINE xas_write_restart(xas_env, xas_section, qs_env, xas_method, iatom, istate)

      TYPE(xas_environment_type), POINTER                :: xas_env
      TYPE(section_vals_type), POINTER                   :: xas_section
      TYPE(qs_environment_type), POINTER                 :: qs_env
      INTEGER, INTENT(IN)                                :: xas_method, iatom, istate

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'xas_write_restart'

      CHARACTER(LEN=default_path_length)                 :: filename
      CHARACTER(LEN=default_string_length)               :: my_middle
      INTEGER                                            :: handle, ispin, nao, nexc_atoms, &
                                                            nexc_search, nmo, output_unit, &
                                                            rst_unit, xas_estate
      REAL(dp)                                           :: occ_estate, xas_nelectron
      REAL(dp), DIMENSION(:), POINTER                    :: eigenvalues, occupation_numbers
      TYPE(cp_fm_type), POINTER                          :: mo_coeff
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(section_vals_type), POINTER                   :: print_key

      CALL timeset(routineN, handle)
      NULLIFY (mos, logger, print_key, particle_set, qs_kind_set)
      logger => cp_get_default_logger()

      CALL get_xas_env(xas_env=xas_env, occ_estate=occ_estate, xas_estate=xas_estate, &
                       xas_nelectron=xas_nelectron, nexc_search=nexc_search, nexc_atoms=nexc_atoms)

      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           xas_section, "PRINT%RESTART", used_print_key=print_key), &
                cp_p_file)) THEN

         output_unit = cp_print_key_unit_nr(logger, xas_section, &
                                            "PRINT%PROGRAM_RUN_INFO", extension=".Log")

         CALL get_qs_env(qs_env=qs_env, mos=mos)

         ! Open file
         rst_unit = -1
         my_middle = 'at'//TRIM(ADJUSTL(cp_to_string(iatom)))//'_st'//TRIM(ADJUSTL(cp_to_string(istate)))
         rst_unit = cp_print_key_unit_nr(logger, xas_section, "PRINT%RESTART", &
                                         extension=".rst", file_status="REPLACE", file_action="WRITE", &
                                         file_form="UNFORMATTED", middle_name=TRIM(my_middle))

         filename = cp_print_key_generate_filename(logger, print_key, &
                                                   middle_name=TRIM(my_middle), extension=".rst", &
                                                   my_local=.FALSE.)

         IF (output_unit > 0) THEN
            WRITE (UNIT=output_unit, FMT="(/,T10,A,I5,A,A,/)") &
               "Xas orbitals  for the absorbing atom ", iatom, &
               " are written in ", TRIM(filename)

         END IF

         ! Write mos
         IF (rst_unit > 0) THEN
            WRITE (rst_unit) xas_method
            WRITE (rst_unit) nexc_search, nexc_atoms, occ_estate, xas_nelectron
            WRITE (rst_unit) xas_estate
         END IF
         DO ispin = 1, SIZE(mos)
            CALL get_mo_set(mos(ispin), mo_coeff=mo_coeff, nao=nao, nmo=nmo, &
                            eigenvalues=eigenvalues, occupation_numbers=occupation_numbers)
            IF ((rst_unit > 0)) THEN
               WRITE (rst_unit) nao, nmo
               WRITE (rst_unit) eigenvalues(1:nmo), &
                  occupation_numbers(1:nmo)
            END IF
            CALL cp_fm_write_unformatted(mo_coeff, rst_unit)
         END DO

! Close file
         CALL cp_print_key_finished_output(rst_unit, logger, xas_section, &
                                           "PRINT%RESTART")
      END IF

      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           xas_section, "PRINT%FULL_RESTART", used_print_key=print_key), &
                cp_p_file)) THEN
         rst_unit = cp_print_key_unit_nr(logger, xas_section, "PRINT%FULL_RESTART", &
                                         extension="_full.rst", file_status="REPLACE", file_action="WRITE", &
                                         file_form="UNFORMATTED", middle_name=TRIM(my_middle))

         CALL get_qs_env(qs_env=qs_env, particle_set=particle_set, qs_kind_set=qs_kind_set)
         CALL write_mo_set_low(mos, particle_set=particle_set, &
                               qs_kind_set=qs_kind_set, ires=rst_unit)
         CALL cp_print_key_finished_output(rst_unit, logger, xas_section, "PRINT%FULL_RESTART")

      END IF

      CALL timestop(handle)

   END SUBROUTINE xas_write_restart

!****f* xas_restart/xas_initialize_rho [1.0] *

! **************************************************************************************************
!> \brief Once the mos and the occupation numbers are initialized
!>      the electronic density of the excited state can be calclated
!> \param qs_env ...
!> \param scf_env ...
!> \param scf_control ...
!> \par History
!>      09-2006 MI created
!> \author MI
! **************************************************************************************************
   SUBROUTINE xas_initialize_rho(qs_env, scf_env, scf_control)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(qs_scf_env_type), POINTER                     :: scf_env
      TYPE(scf_control_type), POINTER                    :: scf_control

      CHARACTER(LEN=*), PARAMETER :: routineN = 'xas_initialize_rho'

      INTEGER                                            :: handle, ispin, my_spin, nelectron
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(rho_atom_type), DIMENSION(:), POINTER         :: rho_atom
      TYPE(xas_environment_type), POINTER                :: xas_env

      CALL timeset(routineN, handle)

      NULLIFY (mos, rho, xas_env, para_env, rho_ao)

      CALL get_qs_env(qs_env, &
                      mos=mos, &
                      rho=rho, &
                      xas_env=xas_env, &
                      para_env=para_env)

      my_spin = xas_env%spin_channel
      CALL qs_rho_get(rho, rho_ao=rho_ao)
      DO ispin = 1, SIZE(mos)
         IF (ispin == my_spin) THEN
            IF (xas_env%homo_occ == 0) THEN
               CALL get_mo_set(mos(ispin), nelectron=nelectron)
               nelectron = nelectron - 1
               CALL set_mo_set(mos(ispin), nelectron=nelectron)
            END IF
            CALL set_mo_occupation(mo_set=qs_env%mos(ispin), smear=scf_control%smear, &
                                   xas_env=xas_env)
         ELSE
            CALL set_mo_occupation(mo_set=qs_env%mos(ispin), smear=scf_control%smear)
         END IF
         CALL calculate_density_matrix(mo_set=mos(ispin), &
                                       density_matrix=rho_ao(ispin)%matrix)
      END DO

      CALL qs_rho_update_rho(rho, qs_env=qs_env)
      CALL qs_ks_did_change(qs_env%ks_env, rho_changed=.TRUE.)

      IF (scf_env%mixing_method > 1) THEN
         CALL get_qs_env(qs_env=qs_env, dft_control=dft_control)
         IF (dft_control%qs_control%dftb .OR. dft_control%qs_control%xtb) THEN
            CPABORT('TB Code not available')
         ELSE IF (dft_control%qs_control%semi_empirical) THEN
            CPABORT('SE Code not possible')
         ELSE
            CALL get_qs_env(qs_env=qs_env, rho_atom_set=rho_atom)
            CALL mixing_init(scf_env%mixing_method, rho, scf_env%mixing_store, &
                             para_env, rho_atom=rho_atom)
         END IF
      END IF

      CALL timestop(handle)

   END SUBROUTINE xas_initialize_rho

! **************************************************************************************************
!> \brief Find the index of the core orbital that has been excited by XAS
!> \param xas_env ...
!> \param mos ...
!> \param matrix_s ...
!> \par History
!>      03-2010 MI created
!> \author MI
! **************************************************************************************************

   SUBROUTINE find_excited_core_orbital(xas_env, mos, matrix_s)

      TYPE(xas_environment_type), POINTER                :: xas_env
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s

      INTEGER                                            :: i, ic_max, ir_max, m, my_spin, n, nao, &
                                                            nexc_search, nmo, xas_estate
      INTEGER, DIMENSION(:), POINTER                     :: col_indices
      REAL(dp)                                           :: a_max, b_max, ip_energy, occ_estate
      REAL(KIND=dp), DIMENSION(:), POINTER               :: eigenvalues, occupation_numbers
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: vecbuffer, vecbuffer2
      TYPE(cp_fm_type)                                   :: fm_work
      TYPE(cp_fm_type), POINTER                          :: excvec_coeff, excvec_overlap, mo_coeff

      NULLIFY (excvec_coeff, excvec_overlap, mo_coeff)
      ! Some elements from the xas_env
      CALL get_xas_env(xas_env=xas_env, excvec_coeff=excvec_coeff, &
                       excvec_overlap=excvec_overlap, nexc_search=nexc_search, &
                       xas_estate=xas_estate, occ_estate=occ_estate, spin_channel=my_spin)
      CPASSERT(ASSOCIATED(excvec_overlap))

      CALL get_mo_set(mos(my_spin), mo_coeff=mo_coeff, nao=nao, nmo=nmo, &
                      eigenvalues=eigenvalues, occupation_numbers=occupation_numbers)
      ALLOCATE (vecbuffer(1, nao))
      vecbuffer = 0.0_dp
      ALLOCATE (vecbuffer2(1, nexc_search))
      vecbuffer2 = 0.0_dp

      ! ** use the maximum overlap criterion to find the index of the excited orbital
      CALL cp_fm_create(fm_work, mo_coeff%matrix_struct)
      CALL cp_dbcsr_sm_fm_multiply(matrix_s(1)%matrix, mo_coeff, fm_work, ncol=nmo)
      CALL parallel_gemm("T", "N", 1, xas_env%nexc_search, nao, 1.0_dp, excvec_coeff, &
                         fm_work, 0.0_dp, excvec_overlap, b_first_col=1)
      CALL cp_fm_get_info(matrix=excvec_overlap, col_indices=col_indices, &
                          nrow_global=m, ncol_global=n)
      CALL cp_fm_get_submatrix(excvec_overlap, vecbuffer2, 1, 1, &
                               1, nexc_search, transpose=.FALSE.)
      CALL cp_fm_release(fm_work)

      b_max = 0.0_dp
      ic_max = xas_estate
      DO i = 1, nexc_search
         a_max = ABS(vecbuffer2(1, i))
         IF (a_max > b_max) THEN
            ic_max = i

            b_max = a_max
         END IF
      END DO

      IF (ic_max /= xas_estate) THEN
         ir_max = xas_estate
         xas_estate = ic_max
         occupation_numbers(xas_estate) = occ_estate
         occupation_numbers(ir_max) = 1.0_dp
      END IF

      ! Ionization Potential
      iP_energy = eigenvalues(xas_estate)
      CALL set_xas_env(xas_env=xas_env, xas_estate=xas_estate, ip_energy=ip_energy)

      CALL cp_fm_get_submatrix(mo_coeff, vecbuffer, 1, xas_estate, &
                               nao, 1, transpose=.TRUE.)
      CALL cp_fm_set_submatrix(excvec_coeff, vecbuffer, 1, 1, &
                               nao, 1, transpose=.TRUE.)

      DEALLOCATE (vecbuffer, vecbuffer2)

   END SUBROUTINE find_excited_core_orbital

END MODULE xas_restart
