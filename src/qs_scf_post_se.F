!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Does all kind of post scf calculations for semi-empirical
!> \par History
!>      Started printing preliminary stuff for MO_CUBES and MO requires some
!>      more work to complete all other functionalities
!>      - Revise MO information printout (10.05.2021, MK)
!> \author Teodoro Laino (07.2008)
! **************************************************************************************************
MODULE qs_scf_post_se

   USE ai_moments,                      ONLY: moment
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind
   USE basis_set_types,                 ONLY: gto_basis_set_type
   USE cell_types,                      ONLY: cell_type,&
                                              pbc
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_output,                 ONLY: cp_dbcsr_write_sparse_matrix
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_io_unit,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_p_file,&
                                              cp_print_key_finished_output,&
                                              cp_print_key_should_output,&
                                              cp_print_key_unit_nr
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_result_methods,               ONLY: cp_results_erase,&
                                              put_results
   USE cp_result_types,                 ONLY: cp_result_type
   USE dbcsr_api,                       ONLY: dbcsr_get_block_p,&
                                              dbcsr_p_type
   USE input_section_types,             ONLY: section_get_ival,&
                                              section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE mathconstants,                   ONLY: twopi
   USE message_passing,                 ONLY: mp_sum
   USE moments_utils,                   ONLY: get_reference_point
   USE orbital_pointers,                ONLY: coset,&
                                              ncoset
   USE particle_list_types,             ONLY: particle_list_type
   USE particle_types,                  ONLY: particle_type
   USE physcon,                         ONLY: debye
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              qs_kind_type
   USE qs_ks_methods,                   ONLY: qs_ks_update_qs_env
   USE qs_ks_types,                     ONLY: qs_ks_did_change
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE qs_scf_output,                   ONLY: qs_scf_write_mos
   USE qs_scf_types,                    ONLY: qs_scf_env_type
   USE qs_subsys_types,                 ONLY: qs_subsys_get,&
                                              qs_subsys_type
   USE semi_empirical_types,            ONLY: get_se_param,&
                                              semi_empirical_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   ! Global parameters
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_scf_post_se'
   PUBLIC :: scf_post_calculation_se

CONTAINS

! **************************************************************************************************
!> \brief collects possible post - scf calculations and prints info / computes properties.
!>        specific for Semi-empirical calculations
!> \param qs_env the qs_env in which the qs_env lives
!> \par History
!>      07.2008 created [tlaino] - Split from qs_scf_post (general)
!> \author tlaino
!> \note
!>      this function changes mo_eigenvectors and mo_eigenvalues, depending on the print keys.
!>      In particular, MO_CUBES causes the MOs to be rotated to make them eigenstates of the KS
!>      matrix, and mo_eigenvalues is updated accordingly. This can, for unconverged wavefunctions,
!>      change afterwards slightly the forces (hence small numerical differences between MD
!>      with and without the debug print level). Ideally this should not happen...
! **************************************************************************************************
   SUBROUTINE scf_post_calculation_se(qs_env)

      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(len=*), PARAMETER :: routineN = 'scf_post_calculation_se'

      INTEGER                                            :: handle, output_unit
      LOGICAL                                            :: explicit, my_localized_wfn
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(particle_list_type), POINTER                  :: particles
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(qs_subsys_type), POINTER                      :: subsys
      TYPE(section_vals_type), POINTER                   :: input, print_key, wfn_mix_section

      CALL timeset(routineN, handle)

      ! Writes the data that is already available in qs_env
      CALL write_available_results(qs_env)

      my_localized_wfn = .FALSE.
      NULLIFY (rho, subsys, particles, input, print_key, para_env)

      logger => cp_get_default_logger()
      output_unit = cp_logger_get_default_io_unit(logger)

      CPASSERT(ASSOCIATED(qs_env))
      ! Here we start with data that needs a postprocessing...
      CALL get_qs_env(qs_env, &
                      rho=rho, &
                      input=input, &
                      subsys=subsys, &
                      para_env=para_env)
      CALL qs_subsys_get(subsys, particles=particles)

      ! Compute Atomic Charges
      CALL qs_scf_post_charges(input, logger, qs_env, rho, para_env)

      ! Moments of charge distribution
      CALL qs_scf_post_moments(input, logger, qs_env)

      ! MO_CUBES
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%MO_CUBES")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("Printing of MO cube files not implemented for Semi-Empirical method.")
      END IF

      ! STM
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%STM")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("STM not implemented for Semi-Empirical method.")
      END IF

      ! DFT+U
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%PLUS_U")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("DFT+U not available for Semi-Empirical method.")
      END IF

      ! Kinetic Energy
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%KINETIC_ENERGY")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("Kinetic energy not available for Semi-Empirical method.")
      END IF

      ! Wavefunction mixing
      wfn_mix_section => section_vals_get_subs_vals(input, "DFT%PRINT%WFN_MIX")
      CALL section_vals_get(wfn_mix_section, explicit=explicit)
      IF (explicit .AND. .NOT. qs_env%run_rtp) THEN
         CPWARN("Wavefunction mixing not implemented for Semi-Empirical  method.")
      END IF

      ! Print coherent X-ray diffraction spectrum
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%XRAY_DIFFRACTION_SPECTRUM")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("XRAY_DIFFRACTION_SPECTRUM  not implemented for Semi-Empirical calculations!!")
      END IF

      ! Calculation of Electric Field Gradients
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%ELECTRIC_FIELD_GRADIENT")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("ELECTRIC_FIELD_GRADIENT not implemented for Semi-Empirical calculations!!")
      END IF

      ! Calculation of EPR Hyperfine Coupling Tensors
      print_key => section_vals_get_subs_vals(section_vals=input, &
                                              subsection_name="DFT%PRINT%HYPERFINE_COUPLING_TENSOR")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), &
                cp_p_file)) THEN
         CPWARN("HYPERFINE_COUPLING_TENSOR  not implemented for Semi-Empirical calculations!!")
      END IF

      CALL timestop(handle)

   END SUBROUTINE scf_post_calculation_se

! **************************************************************************************************
!> \brief Computes and prints electric dipole moments
!>        We use the approximation for NDDO from
!>        Pople and Beveridge, Approximate Molecular Orbital Theory,
!>        Mc Graw Hill 1970
!>        mu = \sum_A [ Q_A * R_a + Tr(P_A*D_A) ]
!> \param input ...
!> \param logger ...
!> \param qs_env the qs_env in which the qs_env lives
! **************************************************************************************************
   SUBROUTINE qs_scf_post_moments(input, logger, qs_env)
      TYPE(section_vals_type), POINTER                   :: input
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(LEN=default_string_length)               :: description, dipole_type
      COMPLEX(KIND=dp)                                   :: dzeta, zeta
      COMPLEX(KIND=dp), DIMENSION(3)                     :: dggamma, dzphase, ggamma, zphase
      INTEGER                                            :: i, iat, iatom, ikind, ix, j, nat, natom, &
                                                            natorb, nkind, nspin, reference, &
                                                            unit_nr
      LOGICAL                                            :: do_berry, found
      REAL(KIND=dp) :: charge_tot, ci(3), dci(3), dipole(3), dipole_deriv(3), drcc(3), dria(3), &
         dtheta, gvec(3), q, rcc(3), ria(3), tcharge(2), theta, tmp(3), via(3), zeff
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: ncharge
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :)     :: mom
      REAL(KIND=dp), DIMENSION(:), POINTER               :: ref_point
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: pblock
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cell_type), POINTER                           :: cell
      TYPE(cp_result_type), POINTER                      :: results
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_p
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(gto_basis_set_type), POINTER                  :: basis_set
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(section_vals_type), POINTER                   :: print_key
      TYPE(semi_empirical_type), POINTER                 :: se_kind

      NULLIFY (results)
      print_key => section_vals_get_subs_vals(input, "DFT%PRINT%MOMENTS")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         ! Dipole Moments
         unit_nr = cp_print_key_unit_nr(logger, input, "DFT%PRINT%MOMENTS", &
                                        extension=".data", middle_name="se_dipole", log_filename=.FALSE.)

         ! Reference point
         reference = section_get_ival(print_key, keyword_name="REFERENCE")
         NULLIFY (ref_point)
         description = '[DIPOLE]'
         CALL section_vals_val_get(print_key, "REF_POINT", r_vals=ref_point)
         CALL section_vals_val_get(print_key, "PERIODIC", l_val=do_berry)
         CALL get_reference_point(rcc, drcc, qs_env=qs_env, reference=reference, &
                                  ref_point=ref_point)
         !
         NULLIFY (particle_set)
         CALL get_qs_env(qs_env=qs_env, &
                         rho=rho, &
                         cell=cell, &
                         atomic_kind_set=atomic_kind_set, &
                         natom=natom, &
                         qs_kind_set=qs_kind_set, &
                         particle_set=particle_set, &
                         results=results, &
                         dft_control=dft_control)

         CALL qs_rho_get(rho, rho_ao=matrix_p)
         nspin = SIZE(matrix_p)
         nkind = SIZE(atomic_kind_set)
         ! net charges
         ALLOCATE (ncharge(natom))
         ncharge = 0.0_dp
         DO ikind = 1, nkind
            CALL get_atomic_kind(atomic_kind_set(ikind), natom=nat)
            CALL get_qs_kind(qs_kind_set(ikind), se_parameter=se_kind)
            CALL get_se_param(se_kind, zeff=zeff, natorb=natorb)
            DO iatom = 1, nat
               iat = atomic_kind_set(ikind)%atom_list(iatom)
               tcharge = 0.0_dp
               DO i = 1, nspin
                  CALL dbcsr_get_block_p(matrix=matrix_p(i)%matrix, row=iat, col=iat, &
                                         block=pblock, found=found)
                  IF (found) THEN
                     DO j = 1, natorb
                        tcharge(i) = tcharge(i) + pblock(j, j)
                     END DO
                  END IF
               END DO
               ncharge(iat) = zeff - SUM(tcharge)
            END DO
         END DO
         ! Contributions from net atomic charges
         ! Dipole deriv will be the derivative of the Dipole(dM/dt=\sum e_j v_j)
         dipole_deriv = 0.0_dp
         dipole = 0.0_dp
         IF (do_berry) THEN
            dipole_type = "periodic (Berry phase)"
            rcc = pbc(rcc, cell)
            charge_tot = 0._dp
            charge_tot = SUM(ncharge)
            ria = twopi*MATMUL(cell%h_inv, rcc)
            zphase = CMPLX(COS(ria), SIN(ria), dp)**charge_tot

            dria = twopi*MATMUL(cell%h_inv, drcc)
            dzphase = charge_tot*CMPLX(-SIN(ria), COS(ria), dp)**(charge_tot - 1.0_dp)*dria

            ggamma = CMPLX(1.0_dp, 0.0_dp, KIND=dp)
            dggamma = CMPLX(0.0_dp, 0.0_dp, KIND=dp)
            DO ikind = 1, SIZE(atomic_kind_set)
               CALL get_atomic_kind(atomic_kind_set(ikind), natom=nat)
               DO i = 1, nat
                  iat = atomic_kind_set(ikind)%atom_list(i)
                  ria = particle_set(iat)%r(:)
                  ria = pbc(ria, cell)
                  via = particle_set(iat)%v(:)
                  q = ncharge(iat)
                  DO j = 1, 3
                     gvec = twopi*cell%h_inv(j, :)
                     theta = SUM(ria(:)*gvec(:))
                     dtheta = SUM(via(:)*gvec(:))
                     zeta = CMPLX(COS(theta), SIN(theta), KIND=dp)**(-q)
                     dzeta = -q*CMPLX(-SIN(theta), COS(theta), KIND=dp)**(-q - 1.0_dp)*dtheta
                     dggamma(j) = dggamma(j)*zeta + ggamma(j)*dzeta
                     ggamma(j) = ggamma(j)*zeta
                  END DO
               END DO
            END DO
            dggamma = dggamma*zphase + ggamma*dzphase
            ggamma = ggamma*zphase
            IF (ALL(REAL(ggamma, KIND=dp) /= 0.0_dp)) THEN
               tmp = AIMAG(ggamma)/REAL(ggamma, KIND=dp)
               ci = ATAN(tmp)
               dci = (1.0_dp/(1.0_dp + tmp**2))* &
                     (AIMAG(dggamma)*REAL(ggamma, KIND=dp) - AIMAG(ggamma)* &
                      REAL(dggamma, KIND=dp))/(REAL(ggamma, KIND=dp))**2
               dipole = MATMUL(cell%hmat, ci)/twopi
               dipole_deriv = MATMUL(cell%hmat, dci)/twopi
            END IF
         ELSE
            dipole_type = "non-periodic"
            DO i = 1, natom
               ! no pbc(particle_set(i)%r(:),cell) so that the total dipole is the sum of the molecular dipoles
               ria = particle_set(i)%r(:)
               q = ncharge(i)
               dipole = dipole - q*(ria - rcc)
               dipole_deriv(:) = dipole_deriv(:) - q*(particle_set(i)%v(:) - drcc)
            END DO
         END IF
         ! Contributions from atomic polarization
         ! No contribution to dipole derivatives
         DO ikind = 1, nkind
            CALL get_atomic_kind(atomic_kind_set(ikind), natom=nat)
            CALL get_qs_kind(qs_kind_set(ikind), basis_set=basis_set)
            CALL get_qs_kind(qs_kind_set(ikind), se_parameter=se_kind)
            CALL get_se_param(se_kind, natorb=natorb)
            ALLOCATE (mom(natorb, natorb, 3))
            mom = 0.0_dp
            CALL atomic_moments(mom, basis_set)
            DO iatom = 1, nat
               iat = atomic_kind_set(ikind)%atom_list(iatom)
               DO i = 1, nspin
                  CALL dbcsr_get_block_p(matrix=matrix_p(i)%matrix, row=iat, col=iat, &
                                         block=pblock, found=found)
                  IF (found) THEN
                     CPASSERT(natorb == SIZE(pblock, 1))
                     ix = coset(1, 0, 0) - 1
                     dipole(1) = dipole(1) + SUM(pblock*mom(:, :, ix))
                     ix = coset(0, 1, 0) - 1
                     dipole(2) = dipole(2) + SUM(pblock*mom(:, :, ix))
                     ix = coset(0, 0, 1) - 1
                     dipole(3) = dipole(3) + SUM(pblock*mom(:, :, ix))
                  END IF
               END DO
            END DO
            DEALLOCATE (mom)
         END DO
         CALL cp_results_erase(results=results, description=description)
         CALL put_results(results=results, description=description, &
                          values=dipole(1:3))
         IF (unit_nr > 0) THEN
            WRITE (unit_nr, '(/,T2,A,T31,A50)') &
               'SE_DIPOLE| Dipole type', ADJUSTR(TRIM(dipole_type))
            WRITE (unit_nr, '(T2,A,T30,3(1X,F16.8))') &
               'SE_DIPOLE| Moment [a.u.]', dipole(1:3)
            WRITE (unit_nr, '(T2,A,T30,3(1X,F16.8))') &
               'SE_DIPOLE| Moment [Debye]', dipole(1:3)*debye
            WRITE (unit_nr, '(T2,A,T30,3(1X,F16.8))') &
               'SE_DIPOLE| Derivative [a.u.]', dipole_deriv(1:3)
         END IF
         CALL cp_print_key_finished_output(unit_nr, logger, print_key)
      END IF

   END SUBROUTINE qs_scf_post_moments

! **************************************************************************************************
!> \brief Computes the dipole integrals for an atom (a|x|b), a,b on atom A
!> \param mom ...
!> \param basis_set ...
! **************************************************************************************************
   SUBROUTINE atomic_moments(mom, basis_set)
      REAL(KIND=dp), DIMENSION(:, :, :)                  :: mom
      TYPE(gto_basis_set_type), POINTER                  :: basis_set

      INTEGER                                            :: i, iset, jset, ncoa, ncob, nm, nset, &
                                                            sgfa, sgfb
      INTEGER, DIMENSION(:), POINTER                     :: la_max, la_min, npgf, nsgf
      INTEGER, DIMENSION(:, :), POINTER                  :: first_sgf
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: work
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :)     :: mab
      REAL(KIND=dp), DIMENSION(3)                        :: rac, rbc
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: rpgf, sphi, zet

      rac = 0.0_dp
      rbc = 0.0_dp

      first_sgf => basis_set%first_sgf
      la_max => basis_set%lmax
      la_min => basis_set%lmin
      npgf => basis_set%npgf
      nset = basis_set%nset
      nsgf => basis_set%nsgf_set
      rpgf => basis_set%pgf_radius
      sphi => basis_set%sphi
      zet => basis_set%zet

      nm = 0
      DO iset = 1, nset
         ncoa = npgf(iset)*ncoset(la_max(iset))
         nm = MAX(nm, ncoa)
      END DO
      ALLOCATE (mab(nm, nm, 4), work(nm, nm))

      DO iset = 1, nset
         ncoa = npgf(iset)*ncoset(la_max(iset))
         sgfa = first_sgf(1, iset)
         DO jset = 1, nset
            ncob = npgf(jset)*ncoset(la_max(jset))
            sgfb = first_sgf(1, jset)
            !*** Calculate the primitive integrals ***
            CALL moment(la_max(iset), npgf(iset), zet(:, iset), rpgf(:, iset), la_min(iset), &
                        la_max(jset), npgf(jset), zet(:, jset), rpgf(:, jset), 1, rac, rbc, mab)
            !*** Contraction step ***
            DO i = 1, 3
               CALL dgemm("N", "N", ncoa, nsgf(jset), ncob, 1.0_dp, mab(1, 1, i), SIZE(mab, 1), &
                          sphi(1, sgfb), SIZE(sphi, 1), 0.0_dp, work(1, 1), SIZE(work, 1))
               CALL dgemm("T", "N", nsgf(iset), nsgf(jset), ncoa, 1.0_dp, sphi(1, sgfa), SIZE(sphi, 1), &
                          work(1, 1), SIZE(work, 1), 1.0_dp, mom(sgfa, sgfb, i), SIZE(mom, 1))
            END DO
         END DO
      END DO
      DEALLOCATE (mab, work)

   END SUBROUTINE atomic_moments
! **************************************************************************************************
!> \brief Computes and Prints Atomic Charges with several methods
!> \param input ...
!> \param logger ...
!> \param qs_env the qs_env in which the qs_env lives
!> \param rho ...
!> \param para_env ...
! **************************************************************************************************
   SUBROUTINE qs_scf_post_charges(input, logger, qs_env, rho, para_env)
      TYPE(section_vals_type), POINTER                   :: input
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(cp_para_env_type), POINTER                    :: para_env

      CHARACTER(LEN=2)                                   :: ana
      CHARACTER(LEN=default_string_length)               :: aname
      INTEGER                                            :: i, iat, iatom, ikind, j, nat, natom, &
                                                            natorb, nkind, nspin, unit_nr
      LOGICAL                                            :: found
      REAL(KIND=dp)                                      :: npe, zeff
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: mcharge
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: charges
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: pblock
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_p
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(section_vals_type), POINTER                   :: print_key
      TYPE(semi_empirical_type), POINTER                 :: se_kind

      NULLIFY (particle_set)
      CALL get_qs_env(qs_env=qs_env, &
                      atomic_kind_set=atomic_kind_set, &
                      natom=natom, &
                      qs_kind_set=qs_kind_set, &
                      particle_set=particle_set, &
                      dft_control=dft_control)

      ! Compute the mulliken charges
      print_key => section_vals_get_subs_vals(input, "DFT%PRINT%MULLIKEN")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         unit_nr = cp_print_key_unit_nr(logger, input, "DFT%PRINT%MULLIKEN", extension=".mulliken", log_filename=.FALSE.)
         CALL qs_rho_get(rho, rho_ao=matrix_p)
         nspin = SIZE(matrix_p)
         npe = REAL(para_env%num_pe, KIND=dp)
         ALLOCATE (charges(natom, nspin), mcharge(natom))
         charges = 0.0_dp
         mcharge = 0.0_dp
         ! calculate atomic charges
         nkind = SIZE(atomic_kind_set)
         DO ikind = 1, nkind
            CALL get_atomic_kind(atomic_kind_set(ikind), natom=nat)
            CALL get_qs_kind(qs_kind_set(ikind), se_parameter=se_kind)
            CALL get_se_param(se_kind, zeff=zeff, natorb=natorb)
            DO iatom = 1, nat
               iat = atomic_kind_set(ikind)%atom_list(iatom)
               DO i = 1, nspin
                  CALL dbcsr_get_block_p(matrix=matrix_p(i)%matrix, row=iat, col=iat, &
                                         block=pblock, found=found)
                  IF (found) THEN
                     DO j = 1, natorb
                        charges(iat, i) = charges(iat, i) + pblock(j, j)
                     END DO
                  END IF
               END DO
               mcharge(iat) = zeff/npe - SUM(charges(iat, 1:nspin))
            END DO
         END DO
         !
         CALL mp_sum(charges, para_env%group)
         CALL mp_sum(mcharge, para_env%group)
         !
         IF (unit_nr > 0) THEN
            WRITE (UNIT=unit_nr, FMT="(/,/,T2,A)") "POPULATION ANALYSIS"
            IF (nspin == 1) THEN
               WRITE (UNIT=unit_nr, FMT="(/,T2,A,T70,A)") &
                  " # Atom   Element   Kind        Atomic population", " Net charge"
               DO ikind = 1, nkind
                  CALL get_atomic_kind(atomic_kind_set(ikind), natom=nat)
                  CALL get_qs_kind(qs_kind_set(ikind), se_parameter=se_kind, element_symbol=aname)
                  ana = ADJUSTR(TRIM(ADJUSTL(aname)))
                  DO iatom = 1, nat
                     iat = atomic_kind_set(ikind)%atom_list(iatom)
                     WRITE (UNIT=unit_nr, &
                            FMT="(T2,I7,6X,A2,3X,I6,T39,F12.6,T69,F12.6)") &
                        iat, ana, ikind, charges(iat, 1), mcharge(iat)
                  END DO
               END DO
               WRITE (UNIT=unit_nr, &
                      FMT="(T2,A,T39,F12.6,T69,F12.6,/)") &
                  "# Total charge", SUM(charges(:, 1)), SUM(mcharge(:))
            ELSE
               WRITE (UNIT=unit_nr, FMT="(/,T2,A)") &
                  "# Atom  Element  Kind  Atomic population (alpha,beta)   Net charge  Spin moment"
               DO ikind = 1, nkind
                  CALL get_atomic_kind(atomic_kind_set(ikind), natom=nat)
                  CALL get_qs_kind(qs_kind_set(ikind), se_parameter=se_kind, element_symbol=aname)
                  ana = ADJUSTR(TRIM(ADJUSTL(aname)))
                  DO iatom = 1, nat
                     iat = atomic_kind_set(ikind)%atom_list(iatom)
                     WRITE (UNIT=unit_nr, &
                            FMT="(T2,I6,5X,A2,2X,I6,T29,4(1X,F12.6))") &
                        iat, ana, ikind, charges(iat, 1:2), mcharge(iat), charges(iat, 1) - charges(iat, 2)
                  END DO
               END DO
               WRITE (UNIT=unit_nr, &
                      FMT="(T2,A,T29,4(1X,F12.6),/)") &
                  "# Total charge and spin", SUM(charges(:, 1)), SUM(charges(:, 2)), SUM(mcharge(:))
            END IF
         END IF

         CALL cp_print_key_finished_output(unit_nr, logger, input, "DFT%PRINT%MULLIKEN")

         DEALLOCATE (charges, mcharge)
      END IF

      ! Compute the Lowdin charges
      print_key => section_vals_get_subs_vals(input, "DFT%PRINT%LOWDIN")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("Lowdin charges not available for semi-empirical calculations!")
      END IF

      ! Hirshfeld charges
      print_key => section_vals_get_subs_vals(input, "DFT%PRINT%HIRSHFELD")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("Hirshfeld charges not available for semi-empirical calculations!")
      END IF

      ! MAO
      print_key => section_vals_get_subs_vals(input, "DFT%PRINT%MAO_ANALYSIS")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, print_key), cp_p_file)) THEN
         CPWARN("MAO analysis not available for semi-empirical calculations!")
      END IF

   END SUBROUTINE qs_scf_post_charges

! **************************************************************************************************
!> \brief Write QS results always available (if switched on through the print_keys)
!> \param qs_env the qs_env in which the qs_env lives
! **************************************************************************************************
   SUBROUTINE write_available_results(qs_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(len=*), PARAMETER :: routineN = 'write_available_results'

      INTEGER                                            :: after, handle, ispin, iw, output_unit
      LOGICAL                                            :: omit_headers
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: ks_rmpv, rho_ao
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(particle_list_type), POINTER                  :: particles
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(qs_scf_env_type), POINTER                     :: scf_env
      TYPE(qs_subsys_type), POINTER                      :: subsys
      TYPE(section_vals_type), POINTER                   :: dft_section, input

      CALL timeset(routineN, handle)
      NULLIFY (dft_control, particle_set, rho, ks_rmpv, dft_section, input, &
               particles, subsys, para_env, rho_ao)
      logger => cp_get_default_logger()
      output_unit = cp_logger_get_default_io_unit(logger)

      CPASSERT(ASSOCIATED(qs_env))
      CALL get_qs_env(qs_env, &
                      dft_control=dft_control, &
                      particle_set=particle_set, &
                      rho=rho, &
                      matrix_ks=ks_rmpv, &
                      input=input, &
                      subsys=subsys, &
                      scf_env=scf_env, &
                      para_env=para_env)
      CALL qs_subsys_get(subsys, particles=particles)
      CALL qs_rho_get(rho, rho_ao=rho_ao)

      ! Print MO information if requested
      CALL qs_scf_write_mos(qs_env, scf_env, final_mos=.TRUE.)

      ! Aat the end of SCF printout the projected DOS for each atomic kind
      dft_section => section_vals_get_subs_vals(input, "DFT")
      IF (BTEST(cp_print_key_should_output(logger%iter_info, dft_section, "PRINT%PDOS") &
                , cp_p_file)) THEN
         CPWARN("PDOS not implemented for Semi-Empirical calculations!!")
      END IF

      ! Print the total density (electronic + core charge)
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%TOT_DENSITY_CUBE"), cp_p_file)) THEN
         CPWARN("TOT_DENSITY_CUBE  not implemented for Semi-Empirical calculations!!")
      END IF

      ! Write cube file with electron density
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%E_DENSITY_CUBE"), cp_p_file)) THEN
         CPWARN("E_DENSITY_CUBE not implemented for Semi-Empirical calculations!!")
      END IF ! print key

      ! Write cube file with EFIELD
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%EFIELD_CUBE"), cp_p_file)) THEN
         CPWARN("EFIELD_CUBE not implemented for Semi-Empirical calculations!!")
      END IF ! print key

      ! Write cube file with ELF
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%ELF_CUBE"), cp_p_file)) THEN
         CPWARN("ELF function not implemented for Semi-Empirical calculations!!")
      END IF ! print key

      ! Print the hartree potential
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%V_HARTREE_CUBE"), cp_p_file)) THEN
         CPWARN("V_HARTREE_CUBE not implemented for Semi-Empirical calculations!!")
      END IF

      ! Print the XC potential
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%V_XC_CUBE"), cp_p_file)) THEN
         CPWARN("V_XC_CUBE not available for Semi-Empirical calculations!!")
      END IF

      ! Write the density matrix
      CALL section_vals_val_get(input, "DFT%PRINT%AO_MATRICES%OMIT_HEADERS", l_val=omit_headers)
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%AO_MATRICES/DENSITY"), cp_p_file)) THEN
         iw = cp_print_key_unit_nr(logger, input, "DFT%PRINT%AO_MATRICES/DENSITY", &
                                   extension=".Log")
         CALL section_vals_val_get(input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         after = MIN(MAX(after, 1), 16)
         DO ispin = 1, dft_control%nspins
            CALL cp_dbcsr_write_sparse_matrix(rho_ao(ispin)%matrix, 4, after, qs_env, &
                                              para_env, output_unit=iw, omit_headers=omit_headers)
         END DO
         CALL cp_print_key_finished_output(iw, logger, input, &
                                           "DFT%PRINT%AO_MATRICES/DENSITY")
      END IF

      ! The Kohn-Sham matrix itself
      IF (BTEST(cp_print_key_should_output(logger%iter_info, input, &
                                           "DFT%PRINT%AO_MATRICES/KOHN_SHAM_MATRIX"), cp_p_file)) THEN
         CALL qs_ks_update_qs_env(qs_env, calculate_forces=.FALSE., just_energy=.FALSE.)
         CALL qs_ks_did_change(qs_env%ks_env, rho_changed=.TRUE.)
         iw = cp_print_key_unit_nr(logger, input, "DFT%PRINT%AO_MATRICES/KOHN_SHAM_MATRIX", &
                                   extension=".Log")
         CALL section_vals_val_get(input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         after = MIN(MAX(after, 1), 16)
         CALL cp_dbcsr_write_sparse_matrix(ks_rmpv(1)%matrix, 4, after, qs_env, &
                                           para_env, output_unit=iw, omit_headers=omit_headers)
         CALL cp_print_key_finished_output(iw, logger, input, &
                                           "DFT%PRINT%AO_MATRICES/KOHN_SHAM_MATRIX")
      END IF

      CALL timestop(handle)

   END SUBROUTINE write_available_results

END MODULE qs_scf_post_se
