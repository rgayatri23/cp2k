!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief computes preconditioners, and implements methods to apply them
!>      currently used in qs_ot
!> \par History
!>      - [UB] 2009-05-13 Adding stable approximate inverse (full and sparse)
!> \author Joost VandeVondele (09.2002)
! **************************************************************************************************
MODULE preconditioner
   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm
   USE cp_fm_types,                     ONLY: cp_fm_get_info,&
                                              cp_fm_type
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_p_type,&
                                              dbcsr_type
   USE input_constants,                 ONLY: cholesky_reduce,&
                                              ot_precond_full_all,&
                                              ot_precond_full_kinetic,&
                                              ot_precond_full_single,&
                                              ot_precond_full_single_inverse,&
                                              ot_precond_none,&
                                              ot_precond_s_inverse,&
                                              ot_precond_solver_update
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE preconditioner_apply,            ONLY: apply_preconditioner_dbcsr,&
                                              apply_preconditioner_fm
   USE preconditioner_makes,            ONLY: make_preconditioner_matrix
   USE preconditioner_solvers,          ONLY: solve_preconditioner,&
                                              transfer_dbcsr_to_fm,&
                                              transfer_fm_to_dbcsr
   USE preconditioner_types,            ONLY: destroy_preconditioner,&
                                              init_preconditioner,&
                                              preconditioner_p_type,&
                                              preconditioner_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_mo_methods,                   ONLY: calculate_subspace_eigenvalues
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'preconditioner'

   PUBLIC :: make_preconditioner, restart_preconditioner
   PUBLIC :: apply_preconditioner, prepare_preconditioner

! The public interface for apply preconditioner, the routines can be found in preconditioner_apply.F
   INTERFACE apply_preconditioner
      MODULE PROCEDURE apply_preconditioner_dbcsr
      MODULE PROCEDURE apply_preconditioner_fm
   END INTERFACE

! **************************************************************************************************

CONTAINS

! **************************************************************************************************

! creates a preconditioner for the system (H-energy_homo S)
! this preconditioner is (must be) symmetric positive definite.
! currently uses a atom-block-diagonal form
! each block will be  ....
! might overwrite matrix_h, matrix_t

! **************************************************************************************************
!> \brief ...
!> \param preconditioner_env ...
!> \param precon_type ...
!> \param solver_type ...
!> \param matrix_h ...
!> \param matrix_s ...
!> \param matrix_t ...
!> \param mo_set ...
!> \param energy_gap ...
!> \param convert_precond_to_dbcsr ...
!> \param chol_type ...
!> \par History
!>      09.2014 removed some unused or unfinished methods
!>              removed sparse preconditioners and the
!>              sparse approximate inverse at rev 14341 [Florian Schiffmann]
! **************************************************************************************************
   SUBROUTINE make_preconditioner(preconditioner_env, precon_type, solver_type, matrix_h, matrix_s, &
                                  matrix_t, mo_set, energy_gap, convert_precond_to_dbcsr, chol_type)

      TYPE(preconditioner_type)                          :: preconditioner_env
      INTEGER, INTENT(IN)                                :: precon_type, solver_type
      TYPE(dbcsr_type), POINTER                          :: matrix_h
      TYPE(dbcsr_type), OPTIONAL, POINTER                :: matrix_s, matrix_t
      TYPE(mo_set_type), INTENT(IN)                      :: mo_set
      REAL(KIND=dp)                                      :: energy_gap
      LOGICAL, INTENT(IN), OPTIONAL                      :: convert_precond_to_dbcsr
      INTEGER, INTENT(IN), OPTIONAL                      :: chol_type

      CHARACTER(len=*), PARAMETER :: routineN = 'make_preconditioner'

      INTEGER                                            :: handle, k, my_solver_type
      LOGICAL                                            :: my_convert_precond_to_dbcsr, &
                                                            needs_full_spectrum, needs_homo, &
                                                            use_mo_coeff_b
      REAL(KIND=dp)                                      :: energy_homo
      REAL(KIND=dp), DIMENSION(:), POINTER               :: eigenvalues_ot
      TYPE(cp_fm_type), POINTER                          :: mo_coeff
      TYPE(dbcsr_type), POINTER                          :: mo_coeff_b

      CALL timeset(routineN, handle)

      CALL get_mo_set(mo_set=mo_set, mo_coeff=mo_coeff, mo_coeff_b=mo_coeff_b)
      use_mo_coeff_b = mo_set%use_mo_coeff_b
      CALL cp_fm_get_info(mo_coeff, ncol_global=k)

      ! Starting some matrix mess, check where to store the result in preconditioner_env, fm or dbcsr_matrix
      my_convert_precond_to_dbcsr = .FALSE.
      IF (PRESENT(convert_precond_to_dbcsr)) my_convert_precond_to_dbcsr = convert_precond_to_dbcsr

      ! Thanks to the mess with the matrices we need to make sure in this case that the
      ! Previous inverse is properly stored as a sparse matrix, fm gets deallocated here
      ! if it wasn't anyway
      IF (preconditioner_env%solver == ot_precond_solver_update) &
         CALL transfer_fm_to_dbcsr(preconditioner_env%fm, preconditioner_env%dbcsr_matrix, matrix_h)

      needs_full_spectrum = .FALSE.
      needs_homo = .FALSE.

      SELECT CASE (precon_type)
      CASE (ot_precond_full_all)
         needs_full_spectrum = .TRUE.
         ! both of them need the coefficients as fm's, more matrix mess
         IF (use_mo_coeff_b) THEN
            CALL copy_dbcsr_to_fm(mo_coeff_b, mo_coeff)
         END IF
      CASE (ot_precond_full_single)
         needs_homo = .TRUE.
         ! XXXX to be removed if homo estimate only is implemented
         needs_full_spectrum = .TRUE.
      CASE (ot_precond_full_kinetic, ot_precond_s_inverse, ot_precond_full_single_inverse)
         ! these should be happy without an estimate for the homo energy
         ! preconditioning can  not depend on an absolute eigenvalue, only on eigenvalue differences
      CASE DEFAULT
         CPABORT("The preconditioner is unknown ...")
      END SELECT

      energy_homo = 0.0_dp
      IF (needs_full_spectrum) THEN
         ALLOCATE (eigenvalues_ot(k))
         ! XXXXXXXXXXXXXXXX do not touch the initial MOs, could be harmful for either
         !                  the case of non-equivalent MOs but also for the derivate
         ! we could already have all eigenvalues e.g. full_all and we could skip this
         ! to be optimised later.
         ! one flaw is that not all SCF methods (i.e. that go over mo_derivs directly)
         ! have a 'valid' matrix_h... (we even don't know what evals are in that case)
         IF (use_mo_coeff_b) THEN
            CALL calculate_subspace_eigenvalues(mo_coeff_b, matrix_h, &
                                                eigenvalues_ot, do_rotation=.FALSE., &
                                                para_env=mo_coeff%matrix_struct%para_env, &
                                                blacs_env=mo_coeff%matrix_struct%context)
         ELSE
            CALL calculate_subspace_eigenvalues(mo_coeff, matrix_h, &
                                                eigenvalues_ot, do_rotation=.FALSE.)
         END IF
         IF (k > 0) energy_homo = eigenvalues_ot(k)
      ELSE
         IF (needs_homo) THEN
            CPABORT("Not yet implemented")
         END IF
      END IF

      ! After all bits and pieces of checking and initialization, here comes the
      ! part where the preconditioner matrix gets created and solved.
      ! This will give the matrices for later use
      my_solver_type = solver_type
      preconditioner_env%in_use = precon_type
      preconditioner_env%cholesky_use = cholesky_reduce
!dbg
!      write(*,*) PRESENT(chol_type)
!      IF(PRESENT(chol_type))  write(*,*) chol_type, cholesky_reduce
!      stop
!dbg
      IF (PRESENT(chol_type)) preconditioner_env%cholesky_use = chol_type
      preconditioner_env%in_use = precon_type
      CALL make_preconditioner_matrix(preconditioner_env, matrix_h, matrix_s, matrix_t, mo_coeff, &
                                      energy_homo, eigenvalues_ot, energy_gap, &
                                      my_solver_type)

      CALL solve_preconditioner(my_solver_type, preconditioner_env, matrix_s, matrix_h)

      ! Here comes more matrix mess, make sure to output the correct matrix format,
      ! A bit pointless to convert the cholesky factorized version as it doesn't work in
      ! dbcsr form and will crash later,...
      IF (my_convert_precond_to_dbcsr) THEN
         CALL transfer_fm_to_dbcsr(preconditioner_env%fm, preconditioner_env%dbcsr_matrix, matrix_h)
      ELSE
         CALL transfer_dbcsr_to_fm(preconditioner_env%dbcsr_matrix, preconditioner_env%fm, &
                                   preconditioner_env%para_env, preconditioner_env%ctxt)
      END IF

      IF (needs_full_spectrum) THEN
         DEALLOCATE (eigenvalues_ot)
      END IF

      CALL timestop(handle)

   END SUBROUTINE make_preconditioner

! **************************************************************************************************
!> \brief Allows for a restart of the preconditioner
!>        depending on the method it purges all arrays or keeps them
!> \param qs_env ...
!> \param preconditioner ...
!> \param prec_type ...
!> \param nspins ...
! **************************************************************************************************
   SUBROUTINE restart_preconditioner(qs_env, preconditioner, prec_type, nspins)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(preconditioner_p_type), DIMENSION(:), POINTER :: preconditioner
      INTEGER, INTENT(IN)                                :: prec_type, nspins

      INTEGER                                            :: ispin
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      TYPE(cp_para_env_type), POINTER                    :: para_env

      NULLIFY (para_env, blacs_env)
      CALL get_qs_env(qs_env, para_env=para_env, blacs_env=blacs_env)

      IF (ASSOCIATED(preconditioner)) THEN
         SELECT CASE (prec_type)
         CASE (ot_precond_full_all, ot_precond_full_single) ! these depend on the ks matrix
            DO ispin = 1, SIZE(preconditioner)
               CALL destroy_preconditioner(preconditioner(ispin)%preconditioner)
               DEALLOCATE (preconditioner(ispin)%preconditioner)
            END DO
            DEALLOCATE (preconditioner)
         CASE (ot_precond_none, ot_precond_full_kinetic, ot_precond_s_inverse, ot_precond_full_single_inverse) ! these are 'independent'
            ! do nothing
         CASE DEFAULT
            CPABORT("")
         END SELECT
      END IF

      ! add an OT preconditioner if none is present
      IF (.NOT. ASSOCIATED(preconditioner)) THEN
         SELECT CASE (prec_type)
         CASE (ot_precond_full_all, ot_precond_full_single_inverse)
            ALLOCATE (preconditioner(nspins))
         CASE DEFAULT
            ALLOCATE (preconditioner(1))
         END SELECT
         DO ispin = 1, SIZE(preconditioner)
            ALLOCATE (preconditioner(ispin)%preconditioner)
            CALL init_preconditioner(preconditioner(ispin)%preconditioner, &
                                     para_env=para_env, &
                                     blacs_env=blacs_env)
         END DO
      END IF

   END SUBROUTINE restart_preconditioner

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
!> \param mos ...
!> \param matrix_ks ...
!> \param matrix_s ...
!> \param ot_preconditioner ...
!> \param prec_type ...
!> \param solver_type ...
!> \param energy_gap ...
!> \param nspins ...
!> \param has_unit_metric ...
!> \param convert_to_dbcsr ...
!> \param chol_type ...
! **************************************************************************************************
   SUBROUTINE prepare_preconditioner(qs_env, mos, matrix_ks, matrix_s, &
                                     ot_preconditioner, prec_type, solver_type, &
                                     energy_gap, nspins, has_unit_metric, &
                                     convert_to_dbcsr, chol_type)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(mo_set_type), DIMENSION(:), INTENT(IN)        :: mos
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_ks, matrix_s
      TYPE(preconditioner_p_type), DIMENSION(:), POINTER :: ot_preconditioner
      INTEGER, INTENT(IN)                                :: prec_type, solver_type
      REAL(dp), INTENT(IN)                               :: energy_gap
      INTEGER, INTENT(IN)                                :: nspins
      LOGICAL, INTENT(IN), OPTIONAL                      :: has_unit_metric, convert_to_dbcsr
      INTEGER, INTENT(IN), OPTIONAL                      :: chol_type

      CHARACTER(LEN=*), PARAMETER :: routineN = 'prepare_preconditioner'

      CHARACTER(LEN=default_string_length)               :: msg
      INTEGER                                            :: handle, icall, ispin, n_loops
      LOGICAL                                            :: do_co_rotate, my_convert_to_dbcsr, &
                                                            my_has_unit_metric, use_mo_coeff_b
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      TYPE(cp_fm_type), POINTER                          :: mo_coeff
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: kinetic
      TYPE(dbcsr_type), POINTER                          :: matrix_t, mo_coeff_b
      TYPE(dft_control_type), POINTER                    :: dft_control

      CALL timeset(routineN, handle)
      NULLIFY (matrix_t, mo_coeff_b, mo_coeff, kinetic, dft_control, para_env, blacs_env)
      my_has_unit_metric = .FALSE.
      IF (PRESENT(has_unit_metric)) my_has_unit_metric = has_unit_metric
      my_convert_to_dbcsr = .TRUE.
      IF (PRESENT(convert_to_dbcsr)) my_convert_to_dbcsr = convert_to_dbcsr

      CALL get_qs_env(qs_env, &
                      dft_control=dft_control, &
                      para_env=para_env, &
                      blacs_env=blacs_env)

      IF (dft_control%qs_control%semi_empirical .OR. dft_control%qs_control%dftb .OR. &
          dft_control%qs_control%xtb) THEN
         IF (prec_type == ot_precond_full_kinetic) THEN
            msg = "Full_kinetic not available for semi-empirical methods"
            CPABORT(TRIM(msg))
         END IF
         matrix_t => matrix_s(1)%matrix
      ELSE
         CPASSERT(.NOT. my_has_unit_metric)
         CALL get_qs_env(qs_env, kinetic=kinetic)
         matrix_t => kinetic(1)%matrix
      END IF

      !determines how often make preconditioner is called, spin dependent methods have to be called twice
      n_loops = 1
      IF (prec_type == ot_precond_full_single_inverse) n_loops = nspins
      ! check whether we need the ev and rotate the MOs
      SELECT CASE (prec_type)
      CASE (ot_precond_full_all)
         ! if one of these preconditioners is used every spin needs to call make_preconditioner
         n_loops = nspins

         do_co_rotate = ASSOCIATED(qs_env%mo_derivs)
         DO ispin = 1, nspins
            CALL get_mo_set(mo_set=mos(ispin), mo_coeff_b=mo_coeff_b, mo_coeff=mo_coeff)
            use_mo_coeff_b = mos(ispin)%use_mo_coeff_b
            IF (use_mo_coeff_b .AND. do_co_rotate) THEN
               CALL calculate_subspace_eigenvalues(mo_coeff_b, matrix_ks(ispin)%matrix, &
                                                   do_rotation=.TRUE., &
                                                   co_rotate=qs_env%mo_derivs(ispin)%matrix, &
                                                   para_env=para_env, &
                                                   blacs_env=blacs_env)
            ELSEIF (use_mo_coeff_b) THEN
               CALL calculate_subspace_eigenvalues(mo_coeff_b, matrix_ks(ispin)%matrix, &
                                                   do_rotation=.TRUE., &
                                                   para_env=para_env, &
                                                   blacs_env=blacs_env)
            ELSE
               CALL calculate_subspace_eigenvalues(mo_coeff, matrix_ks(ispin)%matrix, &
                                                   do_rotation=.TRUE.)
            END IF
         END DO
      CASE DEFAULT
         ! No need to rotate the MOs
      END SELECT

      ! check whether we have a preconditioner
      SELECT CASE (prec_type)
      CASE (ot_precond_none)
         DO ispin = 1, SIZE(ot_preconditioner)
            ot_preconditioner(ispin)%preconditioner%in_use = 0
         END DO
      CASE DEFAULT
         DO icall = 1, n_loops
            IF (my_has_unit_metric) THEN
               CALL make_preconditioner(ot_preconditioner(icall)%preconditioner, &
                                        prec_type, &
                                        solver_type, &
                                        matrix_h=matrix_ks(icall)%matrix, &
                                        mo_set=mos(icall), &
                                        energy_gap=energy_gap, &
                                        convert_precond_to_dbcsr=my_convert_to_dbcsr)
            ELSE
               CALL make_preconditioner(ot_preconditioner(icall)%preconditioner, &
                                        prec_type, &
                                        solver_type, &
                                        matrix_h=matrix_ks(icall)%matrix, &
                                        matrix_s=matrix_s(1)%matrix, &
                                        matrix_t=matrix_t, &
                                        mo_set=mos(icall), &
                                        energy_gap=energy_gap, &
                                        convert_precond_to_dbcsr=my_convert_to_dbcsr, chol_type=chol_type)
            END IF
         END DO
      END SELECT

      CALL timestop(handle)

   END SUBROUTINE prepare_preconditioner

END MODULE preconditioner

