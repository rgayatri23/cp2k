!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Methods using the PEXSI library to calculate the density matrix and
!>        related quantities using the Kohn-Sham and overlap matrices from the
!>        linear scaling quickstep SCF environment.
!> \par History
!>       2014.11 created [Patrick Seewald]
!> \author Patrick Seewald
! **************************************************************************************************

MODULE pexsi_methods
   USE arnoldi_api,                     ONLY: arnoldi_data_type,&
                                              arnoldi_ev,&
                                              deallocate_arnoldi_data,&
                                              get_selected_ritz_val,&
                                              get_selected_ritz_vector,&
                                              set_arnoldi_initial_vector,&
                                              setup_arnoldi_data
   USE cp_dbcsr_cp2k_link,              ONLY: cp_dbcsr_to_csr_screening
   USE cp_dbcsr_operations,             ONLY: dbcsr_allocate_matrix_set
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type
   USE dbcsr_api,                       ONLY: &
        dbcsr_convert_csr_to_dbcsr, dbcsr_convert_dbcsr_to_csr, dbcsr_copy, &
        dbcsr_copy_into_existing, dbcsr_create, dbcsr_csr_create, dbcsr_csr_create_from_dbcsr, &
        dbcsr_csr_destroy, dbcsr_csr_eqrow_floor_dist, dbcsr_csr_print_sparsity, &
        dbcsr_desymmetrize, dbcsr_distribution_get, dbcsr_distribution_type, dbcsr_get_info, &
        dbcsr_has_symmetry, dbcsr_p_type, dbcsr_release, dbcsr_scale, dbcsr_set, dbcsr_type, &
        dbcsr_type_no_symmetry, dbcsr_type_real_8
   USE dm_ls_scf_qs,                    ONLY: matrix_ls_to_qs
   USE dm_ls_scf_types,                 ONLY: ls_scf_env_type
   USE input_section_types,             ONLY: section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp,&
                                              int_4,&
                                              int_8
   USE message_passing,                 ONLY: mp_bcast
   USE pexsi_interface,                 ONLY: cp_pexsi_dft_driver,&
                                              cp_pexsi_get_options,&
                                              cp_pexsi_load_real_hs_matrix,&
                                              cp_pexsi_retrieve_real_dft_matrix,&
                                              cp_pexsi_set_default_options,&
                                              cp_pexsi_set_options
   USE pexsi_types,                     ONLY: convert_nspin_cp2k_pexsi,&
                                              cp2k_to_pexsi,&
                                              lib_pexsi_env,&
                                              pexsi_to_cp2k
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_ks_types,                     ONLY: qs_ks_env_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'pexsi_methods'

   LOGICAL, PARAMETER, PRIVATE          :: careful_mod = .FALSE.

   PUBLIC :: density_matrix_pexsi, pexsi_init_read_input, pexsi_to_qs, pexsi_init_scf, pexsi_finalize_scf, &
             pexsi_set_convergence_tolerance

CONTAINS

! **************************************************************************************************
!> \brief Read CP2K input section PEXSI and pass it to the PEXSI environment
!> \param pexsi_section ...
!> \param pexsi_env ...
!> \par History
!>      11.2014 created [Patrick Seewald]
!> \author Patrick Seewald
! **************************************************************************************************
   SUBROUTINE pexsi_init_read_input(pexsi_section, pexsi_env)
      TYPE(section_vals_type), INTENT(IN), POINTER       :: pexsi_section
      TYPE(lib_pexsi_env), INTENT(INOUT)                 :: pexsi_env

      INTEGER                                            :: isInertiaCount_int, maxPEXSIIter, &
                                                            min_ranks_per_pole, npSymbFact, &
                                                            numPole, ordering, rowOrdering, &
                                                            verbosity
      LOGICAL                                            :: csr_screening, isInertiaCount
      REAL(KIND=dp) :: gap, muInertiaExpansion, muInertiaTolerance, muMax0, muMin0, &
         muPEXSISafeGuard, numElectronInitialTolerance, numElectronTargetTolerance, temperature

! Note: omitting the following PEXSI options: deltaE (estimated by Arnoldi
! before invoking PEXSI), mu0 (taken from previous SCF step), matrixType
! (not implemented in PEXSI yet), isSymbolicFactorize (not needed because
! of fixed sparsity pattern)

      CALL section_vals_val_get(pexsi_section, "TEMPERATURE", &
                                r_val=temperature)
      CALL section_vals_val_get(pexsi_section, "GAP", &
                                r_val=gap)
      CALL section_vals_val_get(pexsi_section, "NUM_POLE", &
                                i_val=numPole)
      CALL section_vals_val_get(pexsi_section, "IS_INERTIA_COUNT", &
                                l_val=isInertiaCount)
      CALL section_vals_val_get(pexsi_section, "MAX_PEXSI_ITER", &
                                i_val=maxPEXSIIter)
      CALL section_vals_val_get(pexsi_section, "MU_MIN_0", &
                                r_val=muMin0)
      CALL section_vals_val_get(pexsi_section, "MU_MAX_0", &
                                r_val=muMax0)
      CALL section_vals_val_get(pexsi_section, "MU_INERTIA_TOLERANCE", &
                                r_val=muInertiaTolerance)
      CALL section_vals_val_get(pexsi_section, "MU_INERTIA_EXPANSION", &
                                r_val=muInertiaExpansion)
      CALL section_vals_val_get(pexsi_section, "MU_PEXSI_SAFE_GUARD", &
                                r_val=muPEXSISafeGuard)
      CALL section_vals_val_get(pexsi_section, "NUM_ELECTRON_INITIAL_TOLERANCE", &
                                r_val=numElectronInitialTolerance)
      CALL section_vals_val_get(pexsi_section, "NUM_ELECTRON_PEXSI_TOLERANCE", &
                                r_val=numElectronTargetTolerance)
      CALL section_vals_val_get(pexsi_section, "ORDERING", &
                                i_val=ordering)
      CALL section_vals_val_get(pexsi_section, "ROW_ORDERING", &
                                i_val=rowOrdering)
      CALL section_vals_val_get(pexsi_section, "NP_SYMB_FACT", &
                                i_val=npSymbFact)
      CALL section_vals_val_get(pexsi_section, "VERBOSITY", &
                                i_val=verbosity)
      CALL section_vals_val_get(pexsi_section, "MIN_RANKS_PER_POLE", &
                                i_val=min_ranks_per_pole)
      CALL section_vals_val_get(pexsi_section, "CSR_SCREENING", &
                                l_val=csr_screening)

      isInertiaCount_int = MERGE(1, 0, isInertiaCount) ! is integer in PEXSI

      ! Set default options inside PEXSI
      CALL cp_pexsi_set_default_options(pexsi_env%options)

      ! Pass CP2K input to PEXSI options
      CALL cp_pexsi_set_options(pexsi_env%options, temperature=temperature, gap=gap, &
                                numPole=numPole, isInertiaCount=isInertiaCount_int, maxPEXSIIter=maxPEXSIIter, &
                                muMin0=muMin0, muMax0=muMax0, muInertiaTolerance=muInertiaTolerance, &
                                muInertiaExpansion=muInertiaExpansion, muPEXSISafeGuard=muPEXSISafeGuard, &
                                ordering=ordering, rowOrdering=rowOrdering, npSymbFact=npSymbFact, verbosity=verbosity)

      pexsi_env%num_ranks_per_pole = min_ranks_per_pole ! not a PEXSI option
      pexsi_env%csr_screening = csr_screening

      IF (numElectronInitialTolerance .LT. numElectronTargetTolerance) &
         numElectronInitialTolerance = numElectronTargetTolerance

      pexsi_env%tol_nel_initial = numElectronInitialTolerance
      pexsi_env%tol_nel_target = numElectronTargetTolerance

   END SUBROUTINE pexsi_init_read_input

! **************************************************************************************************
!> \brief Initializations needed before SCF
!> \param ks_env ...
!> \param pexsi_env ...
!> \param template_matrix DBCSR matrix that defines the block structure and
!>        sparsity pattern of all matrices that are sent to PEXSI
! **************************************************************************************************
   SUBROUTINE pexsi_init_scf(ks_env, pexsi_env, template_matrix)
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(lib_pexsi_env), INTENT(INOUT)                 :: pexsi_env
      TYPE(dbcsr_type), INTENT(IN)                       :: template_matrix

      CHARACTER(len=*), PARAMETER                        :: routineN = 'pexsi_init_scf'

      INTEGER                                            :: handle, ispin, unit_nr
      TYPE(cp_logger_type), POINTER                      :: logger

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      ! Create template matrices fixing sparsity pattern for PEXSI

      IF (dbcsr_has_symmetry(template_matrix)) THEN
         CALL dbcsr_copy(pexsi_env%dbcsr_template_matrix_sym, template_matrix, &
                         "symmetric template matrix for CSR conversion")
         CALL dbcsr_desymmetrize(pexsi_env%dbcsr_template_matrix_sym, &
                                 pexsi_env%dbcsr_template_matrix_nonsym)
      ELSE
         CALL dbcsr_copy(pexsi_env%dbcsr_template_matrix_nonsym, template_matrix, &
                         "non-symmetric template matrix for CSR conversion")
         CALL dbcsr_copy(pexsi_env%dbcsr_template_matrix_sym, template_matrix, &
                         "symmetric template matrix for CSR conversion")
      END IF

      CALL dbcsr_create(pexsi_env%csr_sparsity, "CSR sparsity", &
                        template=pexsi_env%dbcsr_template_matrix_sym, &
                        data_type=dbcsr_type_real_8)
      CALL dbcsr_copy(pexsi_env%csr_sparsity, pexsi_env%dbcsr_template_matrix_sym)

      CALL cp_dbcsr_to_csr_screening(ks_env, pexsi_env%csr_sparsity)

      IF (.NOT. pexsi_env%csr_screening) CALL dbcsr_set(pexsi_env%csr_sparsity, 1.0)
      CALL dbcsr_csr_create_from_dbcsr(pexsi_env%dbcsr_template_matrix_nonsym, &
                                       pexsi_env%csr_mat_s, &
                                       dbcsr_csr_eqrow_floor_dist, &
                                       csr_sparsity=pexsi_env%csr_sparsity, &
                                       numnodes=pexsi_env%num_ranks_per_pole)

      IF (unit_nr > 0) WRITE (unit_nr, "(/T2,A)") "SPARSITY OF THE OVERLAP MATRIX IN CSR FORMAT"
      CALL dbcsr_csr_print_sparsity(pexsi_env%csr_mat_s, unit_nr)

      CALL dbcsr_convert_dbcsr_to_csr(pexsi_env%dbcsr_template_matrix_nonsym, pexsi_env%csr_mat_s)

      CALL dbcsr_csr_create(pexsi_env%csr_mat_ks, pexsi_env%csr_mat_s)
      CALL dbcsr_csr_create(pexsi_env%csr_mat_p, pexsi_env%csr_mat_s)
      CALL dbcsr_csr_create(pexsi_env%csr_mat_E, pexsi_env%csr_mat_s)
      CALL dbcsr_csr_create(pexsi_env%csr_mat_F, pexsi_env%csr_mat_s)

      DO ispin = 1, pexsi_env%nspin
         ! max_ev_vector only initialised to avoid warning in case max_scf==0
         CALL dbcsr_create(pexsi_env%matrix_w(ispin)%matrix, "W matrix", &
                           template=template_matrix, matrix_type=dbcsr_type_no_symmetry)
      END DO

      CALL cp_pexsi_set_options(pexsi_env%options, numElectronPEXSITolerance=pexsi_env%tol_nel_initial)

      CALL timestop(handle)

   END SUBROUTINE pexsi_init_scf

! **************************************************************************************************
!> \brief Deallocations and post-processing after SCF
!> \param pexsi_env ...
!> \param mu_spin ...
! **************************************************************************************************
   SUBROUTINE pexsi_finalize_scf(pexsi_env, mu_spin)
      TYPE(lib_pexsi_env), INTENT(INOUT)                 :: pexsi_env
      REAL(KIND=dp), DIMENSION(2), INTENT(IN)            :: mu_spin

      CHARACTER(len=*), PARAMETER :: routineN = 'pexsi_finalize_scf'

      INTEGER                                            :: handle, ispin, unit_nr
      REAL(KIND=dp)                                      :: kTS_total, mu_total
      TYPE(cp_logger_type), POINTER                      :: logger

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      mu_total = SUM(mu_spin(1:pexsi_env%nspin))/REAL(pexsi_env%nspin, KIND=dp)
      kTS_total = SUM(pexsi_env%kTS)
      IF (pexsi_env%nspin .EQ. 1) kTS_total = kTS_total*2.0_dp

      IF (unit_nr > 0) THEN
         WRITE (unit_nr, "(/A,T55,F26.15)") &
            " PEXSI| Electronic entropic energy (a.u.):", kTS_total
         WRITE (unit_nr, "(A,T55,F26.15)") &
            " PEXSI| Chemical potential (a.u.):", mu_total
      END IF

      CALL dbcsr_release(pexsi_env%dbcsr_template_matrix_sym)
      CALL dbcsr_release(pexsi_env%dbcsr_template_matrix_nonsym)
      CALL dbcsr_release(pexsi_env%csr_sparsity)
      CALL dbcsr_csr_destroy(pexsi_env%csr_mat_p)
      CALL dbcsr_csr_destroy(pexsi_env%csr_mat_ks)
      CALL dbcsr_csr_destroy(pexsi_env%csr_mat_s)
      CALL dbcsr_csr_destroy(pexsi_env%csr_mat_E)
      CALL dbcsr_csr_destroy(pexsi_env%csr_mat_F)
      DO ispin = 1, pexsi_env%nspin
         CALL dbcsr_release(pexsi_env%max_ev_vector(ispin))
         CALL dbcsr_release(pexsi_env%matrix_w(ispin)%matrix)
      END DO
      CALL timestop(handle)
      pexsi_env%tol_nel_initial = pexsi_env%tol_nel_target ! Turn off adaptive threshold for subsequent SCF cycles
   END SUBROUTINE pexsi_finalize_scf

! **************************************************************************************************
!> \brief Calculate density matrix, energy-weighted density matrix and entropic
!>        energy contribution with the DFT driver of the PEXSI library.
!> \param[in,out] pexsi_env     PEXSI environment
!> \param[in,out] matrix_p      density matrix returned by PEXSI
!> \param[in,out] matrix_w      energy-weighted density matrix returned by PEXSI
!> \param[out] kTS              entropic energy contribution returned by PEXSI
!> \param[in] matrix_ks         Kohn-Sham matrix from linear scaling QS environment
!> \param[in] matrix_s          overlap matrix from linear scaling QS environment
!> \param[in] nelectron_exact   exact number of electrons
!> \param[out] mu               chemical potential calculated by PEXSI
!> \param[in] iscf              SCF step
!> \param[in] ispin             Number of spin
!> \par History
!>      11.2014 created [Patrick Seewald]
!> \author Patrick Seewald
! **************************************************************************************************
   SUBROUTINE density_matrix_pexsi(pexsi_env, matrix_p, matrix_w, kTS, matrix_ks, matrix_s, &
                                   nelectron_exact, mu, iscf, ispin)
      TYPE(lib_pexsi_env), INTENT(INOUT)                 :: pexsi_env
      TYPE(dbcsr_type), INTENT(INOUT)                    :: matrix_p
      TYPE(dbcsr_p_type), INTENT(INOUT)                  :: matrix_w
      REAL(KIND=dp), INTENT(OUT)                         :: kTS
      TYPE(dbcsr_type), INTENT(IN), TARGET               :: matrix_ks, matrix_s
      INTEGER, INTENT(IN)                                :: nelectron_exact
      REAL(KIND=dp), INTENT(OUT)                         :: mu
      INTEGER, INTENT(IN)                                :: iscf, ispin

      CHARACTER(LEN=*), PARAMETER :: routineN = 'density_matrix_pexsi'
      INTEGER, PARAMETER                                 :: S_not_identity = 0

      INTEGER :: handle, is_symbolic_factorize, isInertiaCount, isInertiaCount_out, mynode, &
         n_total_inertia_iter, n_total_pexsi_iter, unit_nr
      LOGICAL                                            :: first_call, pexsi_convergence
      REAL(KIND=dp) :: delta_E, energy_H, energy_S, free_energy, mu_max_in, mu_max_out, mu_min_in, &
         mu_min_out, nel_tol, nelectron_diff, nelectron_exact_pexsi, nelectron_out
      TYPE(arnoldi_data_type)                            :: my_arnoldi
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_distribution_type)                      :: dist
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: arnoldi_matrices

      CALL timeset(routineN, handle)

      ! get a useful output_unit
      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      first_call = (iscf .EQ. 1) .AND. (ispin .EQ. 1)

      ! Assert a few things the first time PEXSI is called
      IF (first_call) THEN
         ! Assertion that matrices have the expected symmetry (both should be symmetric if no
         ! S preconditioning and no molecular clustering)
         IF (.NOT. dbcsr_has_symmetry(matrix_ks)) &
            CPABORT("PEXSI interface expects a non-symmetric DBCSR Kohn-Sham matrix")
         IF (.NOT. dbcsr_has_symmetry(matrix_s)) &
            CPABORT("PEXSI interface expects a non-symmetric DBCSR overlap matrix")

         ! Assertion on datatype
         IF ((pexsi_env%csr_mat_s%nzval_local%data_type .NE. dbcsr_type_real_8) &
             .OR. (pexsi_env%csr_mat_ks%nzval_local%data_type .NE. dbcsr_type_real_8)) &
            CPABORT("Complex data type not supported by PEXSI")

         ! Assertion on number of non-zero elements
         !(TODO: update when PEXSI changes to Long Int)
         IF (pexsi_env%csr_mat_s%nze_total .GE. INT(2, kind=int_8)**31) &
            CPABORT("Total number of non-zero elements of CSR matrix is too large to be handled by PEXSI")
      END IF

      CALL dbcsr_get_info(matrix_ks, distribution=dist)
      CALL dbcsr_distribution_get(dist, mynode=mynode)

      ! Convert DBCSR matrices to PEXSI CSR format. Intermediate step to template matrix
      ! needed in order to retain the initial sparsity pattern that is required for the
      ! conversion to CSR format.
      CALL dbcsr_copy_into_existing(pexsi_env%dbcsr_template_matrix_sym, matrix_s)
      CALL dbcsr_convert_dbcsr_to_csr(pexsi_env%dbcsr_template_matrix_sym, &
                                      pexsi_env%csr_mat_s)

      CALL dbcsr_copy_into_existing(pexsi_env%dbcsr_template_matrix_sym, &
                                    matrix_ks)
      CALL dbcsr_convert_dbcsr_to_csr(pexsi_env%dbcsr_template_matrix_sym, &
                                      pexsi_env%csr_mat_ks)

      ! Get PEXSI input delta_E (upper bound for largest eigenvalue) using Arnoldi
      NULLIFY (arnoldi_matrices)
      CALL dbcsr_allocate_matrix_set(arnoldi_matrices, 2)
      arnoldi_matrices(1)%matrix => matrix_ks
      arnoldi_matrices(2)%matrix => matrix_s
      CALL setup_arnoldi_data(my_arnoldi, arnoldi_matrices, max_iter=20, &
                              threshold=1.0E-2_dp, selection_crit=2, nval_request=1, nrestarts=21, &
                              generalized_ev=.TRUE., iram=.FALSE.)
      IF (iscf .GT. 1) CALL set_arnoldi_initial_vector(my_arnoldi, pexsi_env%max_ev_vector(ispin))
      CALL arnoldi_ev(arnoldi_matrices, my_arnoldi)
      delta_E = REAL(get_selected_ritz_val(my_arnoldi, 1), dp)
      ! increase delta_E a bit to make sure that it really is an upper bound
      delta_E = delta_E + 1.0E-2_dp*ABS(delta_E)
      CALL get_selected_ritz_vector(my_arnoldi, 1, arnoldi_matrices(1)%matrix, &
                                    pexsi_env%max_ev_vector(ispin))
      CALL deallocate_arnoldi_data(my_arnoldi)
      DEALLOCATE (arnoldi_matrices)

      nelectron_exact_pexsi = nelectron_exact

      CALL cp_pexsi_set_options(pexsi_env%options, deltaE=delta_E)

      ! Set PEXSI options appropriately for first SCF iteration
      IF (iscf .EQ. 1) THEN
         ! Get option isInertiaCount to reset it later on and set it to 1 for first SCF iteration
         CALL cp_pexsi_get_options(pexsi_env%options, isInertiaCount=isInertiaCount)
         CALL cp_pexsi_set_options(pexsi_env%options, isInertiaCount=1, &
                                   isSymbolicFactorize=1)
      END IF

      ! Write PEXSI options to output
      CALL cp_pexsi_get_options(pexsi_env%options, isInertiaCount=isInertiaCount_out, &
                                isSymbolicFactorize=is_symbolic_factorize, &
                                muMin0=mu_min_in, muMax0=mu_max_in, &
                                NumElectronPEXSITolerance=nel_tol)

!    IF(unit_nr>0) WRITE(unit_nr,'(/A,I4,A,I4)') " PEXSI| SCF", iscf, &
!                                                ", spin component", ispin

      IF (unit_nr > 0) WRITE (unit_nr, '(/A,T41,L20)') " PEXSI| Do inertia counting?", &
         isInertiaCount_out .EQ. 1
      IF (unit_nr > 0) WRITE (unit_nr, '(A,T50,F5.2,T56,F5.2)') &
         " PEXSI| Guess for min mu, max mu", mu_min_in, mu_max_in

      IF (unit_nr > 0) WRITE (unit_nr, '(A,T41,E20.3)') &
         " PEXSI| Tolerance in number of electrons", nel_tol

!    IF(unit_nr>0) WRITE(unit_nr,'(A,T41,L20)') &
!                  " PEXSI|   Do symbolic factorization?", is_symbolic_factorize.EQ.1

      IF (unit_nr > 0) WRITE (unit_nr, '(A,T41,F20.2)') &
         " PEXSI| Arnoldi est. spectral radius", delta_E

      ! Load data into PEXSI
      CALL cp_pexsi_load_real_hs_matrix( &
         pexsi_env%plan, &
         pexsi_env%options, &
         pexsi_env%csr_mat_ks%nrows_total, &
         INT(pexsi_env%csr_mat_ks%nze_total, kind=int_4), & ! TODO: update when PEXSI changes to Long Int
         pexsi_env%csr_mat_ks%nze_local, &
         pexsi_env%csr_mat_ks%nrows_local, &
         pexsi_env%csr_mat_ks%rowptr_local, &
         pexsi_env%csr_mat_ks%colind_local, &
         pexsi_env%csr_mat_ks%nzval_local%r_dp, &
         S_not_identity, &
         pexsi_env%csr_mat_s%nzval_local%r_dp)

      ! convert to spin restricted before passing number of electrons to PEXSI
      CALL convert_nspin_cp2k_pexsi(cp2k_to_pexsi, &
                                    numElectron=nelectron_exact_pexsi)

      ! Call DFT driver of PEXSI doing the actual calculation
      CALL cp_pexsi_dft_driver(pexsi_env%plan, pexsi_env%options, &
                               nelectron_exact_pexsi, mu, nelectron_out, mu_min_out, mu_max_out, &
                               n_total_inertia_iter, n_total_pexsi_iter)

      ! Check convergence
      nelectron_diff = nelectron_out - nelectron_exact_pexsi
      pexsi_convergence = ABS(nelectron_diff) .LT. nel_tol

      IF (unit_nr > 0) THEN
         IF (pexsi_convergence) THEN
            WRITE (unit_nr, '(/A)') " PEXSI| Converged"
         ELSE
            WRITE (unit_nr, '(/A)') " PEXSI| PEXSI did not converge!"
         END IF

!      WRITE(unit_nr,'(A,T41,F20.10,T61,F20.10)') " PEXSI|   Number of electrons", &
!                      nelectron_out/pexsi_env%nspin, nelectron_diff/pexsi_env%nspin

         WRITE (unit_nr, '(A,T41,F20.6)') " PEXSI|   Chemical potential", mu

         WRITE (unit_nr, '(A,T41,I20)') " PEXSI|   PEXSI iterations", n_total_pexsi_iter
         WRITE (unit_nr, '(A,T41,I20/)') " PEXSI|   Inertia counting iterations", &
            n_total_inertia_iter
      END IF

      IF (.NOT. pexsi_convergence) &
         CPABORT("PEXSI did not converge. Consider logPEXSI0 for more information.")

      ! Retrieve results from PEXSI
      IF (mynode < pexsi_env%mp_dims(1)*pexsi_env%mp_dims(2)) THEN
         CALL cp_pexsi_retrieve_real_dft_matrix( &
            pexsi_env%plan, &
            pexsi_env%csr_mat_p%nzval_local%r_dp, &
            pexsi_env%csr_mat_E%nzval_local%r_dp, &
            pexsi_env%csr_mat_F%nzval_local%r_dp, &
            energy_H, energy_S, free_energy)
         ! calculate entropic energy contribution -TS = A - U
         kTS = (free_energy - energy_H)
      END IF

      ! send kTS to all nodes:
      CALL mp_bcast(kTS, 0, pexsi_env%mp_group)

      ! Convert PEXSI CSR matrices to DBCSR matrices
      CALL dbcsr_convert_csr_to_dbcsr(pexsi_env%dbcsr_template_matrix_nonsym, &
                                      pexsi_env%csr_mat_p)
      CALL dbcsr_copy(matrix_p, pexsi_env%dbcsr_template_matrix_nonsym)
      CALL dbcsr_convert_csr_to_dbcsr(pexsi_env%dbcsr_template_matrix_nonsym, &
                                      pexsi_env%csr_mat_E)
      CALL dbcsr_copy(matrix_w%matrix, pexsi_env%dbcsr_template_matrix_nonsym)

      ! Convert to spin unrestricted
      CALL convert_nspin_cp2k_pexsi(pexsi_to_cp2k, matrix_p=matrix_p, &
                                    matrix_w=matrix_w, kTS=kTS)

      ! Pass resulting mu as initial guess for next SCF to PEXSI
      CALL cp_pexsi_set_options(pexsi_env%options, mu0=mu, muMin0=mu_min_out, &
                                muMax0=mu_max_out)

      ! Reset isInertiaCount according to user input
      IF (iscf .EQ. 1) THEN
         CALL cp_pexsi_set_options(pexsi_env%options, isInertiaCount= &
                                   isInertiaCount)
      END IF

      ! Turn off symbolic factorization for subsequent calls
      IF (first_call) THEN
         CALL cp_pexsi_set_options(pexsi_env%options, isSymbolicFactorize=0)
      END IF

      CALL timestop(handle)
   END SUBROUTINE density_matrix_pexsi

! **************************************************************************************************
!> \brief Set PEXSI convergence tolerance (numElectronPEXSITolerance), adapted
!>        to the convergence error of the previous SCF step. The tolerance is
!>        calculated using an initial convergence threshold (tol_nel_initial)
!>        and a target convergence threshold (tol_nel_target):
!>        numElectronPEXSITolerance(delta_scf) = alpha*delta_scf+beta
!>        where alpha and beta are chosen such that
!>        numElectronPEXSITolerance(delta_scf_0) = tol_nel_initial
!>        numElectronPEXSITolerance(eps_scf) = tol_nel_target
!>        and delta_scf_0 is the initial SCF convergence error.
!> \param pexsi_env ...
!> \param delta_scf convergence error of previous SCF step
!> \param eps_scf SCF convergence criterion
!> \param initialize whether or not adaptive thresholing should be initialized
!>        with delta_scf as initial convergence error
!> \param check_convergence is set to .FALSE. if convergence in number of electrons
!>        will not be achieved in next SCF step
! **************************************************************************************************
   SUBROUTINE pexsi_set_convergence_tolerance(pexsi_env, delta_scf, eps_scf, initialize, &
                                              check_convergence)
      TYPE(lib_pexsi_env), INTENT(INOUT)                 :: pexsi_env
      REAL(KIND=dp), INTENT(IN)                          :: delta_scf, eps_scf
      LOGICAL, INTENT(IN)                                :: initialize
      LOGICAL, INTENT(OUT)                               :: check_convergence

      CHARACTER(len=*), PARAMETER :: routineN = 'pexsi_set_convergence_tolerance'

      INTEGER                                            :: handle
      REAL(KIND=dp)                                      :: tol_nel

      CALL timeset(routineN, handle)

      tol_nel = pexsi_env%tol_nel_initial

      IF (initialize) THEN
         pexsi_env%adaptive_nel_alpha = &
            (pexsi_env%tol_nel_initial - pexsi_env%tol_nel_target)/(ABS(delta_scf) - eps_scf)
         pexsi_env%adaptive_nel_beta = &
            pexsi_env%tol_nel_initial - pexsi_env%adaptive_nel_alpha*ABS(delta_scf)
         pexsi_env%do_adaptive_tol_nel = .TRUE.
      END IF
      IF (pexsi_env%do_adaptive_tol_nel) THEN
         tol_nel = pexsi_env%adaptive_nel_alpha*ABS(delta_scf) + pexsi_env%adaptive_nel_beta
         tol_nel = MAX(tol_nel, pexsi_env%tol_nel_target)
         tol_nel = MIN(tol_nel, pexsi_env%tol_nel_initial)
      END IF

      check_convergence = (tol_nel .LE. pexsi_env%tol_nel_target)

      CALL cp_pexsi_set_options(pexsi_env%options, numElectronPEXSITolerance=tol_nel)
      CALL timestop(handle)
   END SUBROUTINE

! **************************************************************************************************
!> \brief Pass energy weighted density matrix and entropic energy contribution
!>        to QS environment
!> \param ls_scf_env ...
!> \param qs_env ...
!> \param kTS ...
!> \param matrix_w ...
!> \par History
!>      12.2014 created [Patrick Seewald]
!> \author Patrick Seewald
! **************************************************************************************************
   SUBROUTINE pexsi_to_qs(ls_scf_env, qs_env, kTS, matrix_w)
      TYPE(ls_scf_env_type)                              :: ls_scf_env
      TYPE(qs_environment_type), INTENT(INOUT), POINTER  :: qs_env
      REAL(KIND=dp), DIMENSION(:), INTENT(IN), OPTIONAL  :: kTS
      TYPE(dbcsr_p_type), DIMENSION(:), INTENT(IN), &
         OPTIONAL                                        :: matrix_w

      CHARACTER(len=*), PARAMETER                        :: routineN = 'pexsi_to_qs'

      INTEGER                                            :: handle, ispin, unit_nr
      REAL(KIND=dp)                                      :: kTS_total
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_w_qs
      TYPE(qs_energy_type), POINTER                      :: energy

      CALL timeset(routineN, handle)

      NULLIFY (energy)

      ! get a useful output_unit
      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      CALL get_qs_env(qs_env, energy=energy, matrix_w=matrix_w_qs)

      IF (PRESENT(matrix_w)) THEN
         DO ispin = 1, ls_scf_env%nspins
            CALL matrix_ls_to_qs(matrix_w_qs(ispin)%matrix, matrix_w(ispin)%matrix, &
                                 ls_scf_env%ls_mstruct, covariant=.FALSE.)
            IF (ls_scf_env%nspins .EQ. 1) CALL dbcsr_scale(matrix_w_qs(ispin)%matrix, 2.0_dp)
         END DO
      END IF

      IF (PRESENT(kTS)) THEN
         kTS_total = SUM(kTS)
         IF (ls_scf_env%nspins .EQ. 1) kTS_total = kTS_total*2.0_dp
         energy%kTS = kTS_total
      END IF

      CALL timestop(handle)
   END SUBROUTINE pexsi_to_qs

END MODULE pexsi_methods
