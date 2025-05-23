!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines for propagating the orbitals
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************
MODULE rt_propagation_methods
   USE bibliography,                    ONLY: Kolafa2004,&
                                              Kuhne2007,&
                                              cite_reference
   USE cp_cfm_basic_linalg,             ONLY: cp_cfm_cholesky_decompose,&
                                              cp_cfm_triangular_multiply
   USE cp_cfm_types,                    ONLY: cp_cfm_create,&
                                              cp_cfm_release,&
                                              cp_cfm_type
   USE cp_control_types,                ONLY: rtp_control_type
   USE cp_dbcsr_cholesky,               ONLY: cp_dbcsr_cholesky_decompose,&
                                              cp_dbcsr_cholesky_invert
   USE cp_dbcsr_operations,             ONLY: cp_dbcsr_sm_fm_multiply,&
                                              dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_fm_basic_linalg,              ONLY: cp_fm_scale_and_add
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_double,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_release,&
                                              cp_fm_to_fm,&
                                              cp_fm_type
   USE cp_fm_vect,                      ONLY: cp_fm_vect_dealloc
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type,&
                                              cp_to_string
   USE dbcsr_api,                       ONLY: &
        dbcsr_add, dbcsr_copy, dbcsr_create, dbcsr_deallocate_matrix, dbcsr_desymmetrize, &
        dbcsr_filter, dbcsr_frobenius_norm, dbcsr_get_block_p, dbcsr_init_p, &
        dbcsr_iterator_blocks_left, dbcsr_iterator_next_block, dbcsr_iterator_start, &
        dbcsr_iterator_stop, dbcsr_iterator_type, dbcsr_multiply, dbcsr_p_type, dbcsr_release, &
        dbcsr_scale, dbcsr_set, dbcsr_transposed, dbcsr_type, dbcsr_type_antisymmetric
   USE input_constants,                 ONLY: do_arnoldi,&
                                              do_bch,&
                                              do_em,&
                                              do_pade,&
                                              do_taylor
   USE iterate_matrix,                  ONLY: matrix_sqrt_Newton_Schulz
   USE kinds,                           ONLY: dp
   USE ls_matrix_exp,                   ONLY: cp_complex_dbcsr_gemm_3
   USE mathlib,                         ONLY: binomial
   USE parallel_gemm_api,               ONLY: parallel_gemm
   USE qs_energy_init,                  ONLY: qs_energies_init
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_ks_methods,                   ONLY: qs_ks_update_qs_env
   USE qs_ks_types,                     ONLY: set_ks_env
   USE rt_make_propagators,             ONLY: propagate_arnoldi,&
                                              propagate_bch,&
                                              propagate_exp,&
                                              propagate_exp_density
   USE rt_propagation_output,           ONLY: report_density_occupation,&
                                              rt_convergence,&
                                              rt_convergence_density
   USE rt_propagation_types,            ONLY: get_rtp,&
                                              rt_prop_type
   USE rt_propagation_utils,            ONLY: calc_S_derivs,&
                                              calc_update_rho,&
                                              calc_update_rho_sparse
   USE rt_propagation_velocity_gauge,   ONLY: velocity_gauge_ks_matrix
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_propagation_methods'

   PUBLIC :: propagation_step, &
             s_matrices_create, &
             calc_sinvH, &
             put_data_to_history

CONTAINS

! **************************************************************************************************
!> \brief performs a single propagation step a(t+Dt)=U(t+Dt,t)*a(0)
!>        and calculates the new exponential
!> \param qs_env ...
!> \param rtp ...
!> \param rtp_control ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE propagation_step(qs_env, rtp, rtp_control)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER                        :: routineN = 'propagation_step'

      INTEGER                                            :: aspc_order, handle, i, im, re, unit_nr
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: delta_mos, mos_new
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: delta_P, H_last_iter, ks_mix, ks_mix_im, &
                                                            matrix_ks, matrix_ks_im, matrix_s, &
                                                            rho_new

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      NULLIFY (delta_P, rho_new, delta_mos, mos_new)
      NULLIFY (ks_mix, ks_mix_im)
      ! get everything needed and set some values
      CALL get_qs_env(qs_env, matrix_s=matrix_s)
      IF (rtp%iter == 1) THEN
         CALL qs_energies_init(qs_env, .FALSE.)
         !the above recalculates matrix_s, but matrix not changed if ions are fixed
         IF (rtp_control%fixed_ions) CALL set_ks_env(qs_env%ks_env, s_mstruct_changed=.FALSE.)

         ! add additional terms for the velocity gauge to matrix_h and matrix_h_im
         ! should be called imediately after qs_energies_init and before qs_ks_update_qs_env
         IF (rtp_control%velocity_gauge) THEN
            CALL velocity_gauge_ks_matrix(qs_env, subtract_nl_term=.FALSE.)
         END IF

         CALL get_qs_env(qs_env, matrix_s=matrix_s)
         IF (.NOT. rtp_control%fixed_ions) THEN
            CALL s_matrices_create(matrix_s, rtp)
         END IF
         rtp%delta_iter = 100.0_dp
         rtp%mixing_factor = 1.0_dp
         rtp%mixing = .FALSE.
         aspc_order = rtp_control%aspc_order
         CALL aspc_extrapolate(rtp, matrix_s, aspc_order)
         IF (rtp%linear_scaling) THEN
            CALL calc_update_rho_sparse(qs_env)
         ELSE
            CALL calc_update_rho(qs_env)
         END IF
         CALL qs_ks_update_qs_env(qs_env, calculate_forces=.FALSE.)
      END IF
      IF (.NOT. rtp_control%fixed_ions) THEN
         CALL calc_S_derivs(qs_env)
      END IF
      rtp%converged = .FALSE.

      IF (rtp%linear_scaling) THEN
         ! keep temporary copy of the starting density matrix to check for convergence
         CALL get_rtp(rtp=rtp, rho_new=rho_new)
         NULLIFY (delta_P)
         CALL dbcsr_allocate_matrix_set(delta_P, SIZE(rho_new))
         DO i = 1, SIZE(rho_new)
            CALL dbcsr_init_p(delta_P(i)%matrix)
            CALL dbcsr_create(delta_P(i)%matrix, template=rho_new(i)%matrix)
            CALL dbcsr_copy(delta_P(i)%matrix, rho_new(i)%matrix)
         END DO
      ELSE
         ! keep temporary copy of the starting mos to check for convergence
         CALL get_rtp(rtp=rtp, mos_new=mos_new)
         ALLOCATE (delta_mos(SIZE(mos_new)))
         DO i = 1, SIZE(mos_new)
            CALL cp_fm_create(delta_mos(i), &
                              matrix_struct=mos_new(i)%matrix_struct, &
                              name="delta_mos"//TRIM(ADJUSTL(cp_to_string(i))))
            CALL cp_fm_to_fm(mos_new(i), delta_mos(i))
         END DO
      END IF

      CALL get_qs_env(qs_env, &
                      matrix_ks=matrix_ks, &
                      matrix_ks_im=matrix_ks_im)

      CALL get_rtp(rtp=rtp, H_last_iter=H_last_iter)
      IF (rtp%mixing) THEN
         IF (unit_nr > 0) THEN
            WRITE (unit_nr, '(t3,a,2f16.8)') "Mixing the Hamiltonians to improve robustness, mixing factor: ", rtp%mixing_factor
         END IF
         CALL dbcsr_allocate_matrix_set(ks_mix, SIZE(matrix_ks))
         CALL dbcsr_allocate_matrix_set(ks_mix_im, SIZE(matrix_ks))
         DO i = 1, SIZE(matrix_ks)
            CALL dbcsr_init_p(ks_mix(i)%matrix)
            CALL dbcsr_create(ks_mix(i)%matrix, template=matrix_ks(1)%matrix)
            CALL dbcsr_init_p(ks_mix_im(i)%matrix)
            CALL dbcsr_create(ks_mix_im(i)%matrix, template=matrix_ks(1)%matrix, matrix_type=dbcsr_type_antisymmetric)
         END DO
         DO i = 1, SIZE(matrix_ks)
            re = 2*i - 1
            im = 2*i
            CALL dbcsr_add(ks_mix(i)%matrix, matrix_ks(i)%matrix, 0.0_dp, rtp%mixing_factor)
            CALL dbcsr_add(ks_mix(i)%matrix, H_last_iter(re)%matrix, 1.0_dp, 1.0_dp - rtp%mixing_factor)
            IF (rtp%do_hfx) THEN
               CALL dbcsr_add(ks_mix_im(i)%matrix, matrix_ks_im(i)%matrix, 0.0_dp, rtp%mixing_factor)
               CALL dbcsr_add(ks_mix_im(i)%matrix, H_last_iter(im)%matrix, 1.0_dp, 1.0_dp - rtp%mixing_factor)
            END IF
         END DO
         CALL calc_SinvH(rtp, ks_mix, ks_mix_im, rtp_control)
         DO i = 1, SIZE(matrix_ks)
            re = 2*i - 1
            im = 2*i
            CALL dbcsr_copy(H_last_iter(re)%matrix, ks_mix(i)%matrix)
            IF (rtp%do_hfx) THEN
               CALL dbcsr_copy(H_last_iter(im)%matrix, ks_mix_im(i)%matrix)
            END IF
         END DO
         CALL dbcsr_deallocate_matrix_set(ks_mix)
         CALL dbcsr_deallocate_matrix_set(ks_mix_im)
      ELSE
         CALL calc_SinvH(rtp, matrix_ks, matrix_ks_im, rtp_control)
         DO i = 1, SIZE(matrix_ks)
            re = 2*i - 1
            im = 2*i
            CALL dbcsr_copy(H_last_iter(re)%matrix, matrix_ks(i)%matrix)
            IF (rtp%do_hfx) THEN
               CALL dbcsr_copy(H_last_iter(im)%matrix, matrix_ks_im(i)%matrix)
            END IF
         END DO
      END IF

      CALL compute_propagator_matrix(rtp, rtp_control%propagator)

      SELECT CASE (rtp_control%mat_exp)
      CASE (do_pade, do_taylor)
         IF (rtp%linear_scaling) THEN
            CALL propagate_exp_density(rtp, rtp_control)
            CALL calc_update_rho_sparse(qs_env)
         ELSE
            CALL propagate_exp(rtp, rtp_control)
            CALL calc_update_rho(qs_env)
         END IF
      CASE (do_arnoldi)
         CALL propagate_arnoldi(rtp, rtp_control)
         CALL calc_update_rho(qs_env)
      CASE (do_bch)
         CALL propagate_bch(rtp, rtp_control)
         CALL calc_update_rho_sparse(qs_env)
      END SELECT
      CALL step_finalize(qs_env, rtp_control, delta_mos, delta_P)
      IF (rtp%linear_scaling) THEN
         CALL dbcsr_deallocate_matrix_set(delta_P)
      ELSE
         CALL cp_fm_vect_dealloc(delta_mos)
      END IF

      CALL timestop(handle)

   END SUBROUTINE propagation_step

! **************************************************************************************************
!> \brief Performs all the stuff to finish the step:
!>        convergence checks
!>        copying stuff into right place for the next step
!>        updating the history for extrapolation
!> \param qs_env ...
!> \param rtp_control ...
!> \param delta_mos ...
!> \param delta_P ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE step_finalize(qs_env, rtp_control, delta_mos, delta_P)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(rtp_control_type), POINTER                    :: rtp_control
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: delta_mos
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: delta_P

      CHARACTER(len=*), PARAMETER                        :: routineN = 'step_finalize'

      INTEGER                                            :: handle, i, ihist
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: mos_new, mos_old
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H_new, exp_H_old, matrix_ks, &
                                                            matrix_ks_im, rho_new, rho_old, s_mat
      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(rt_prop_type), POINTER                        :: rtp

      CALL timeset(routineN, handle)

      CALL get_qs_env(qs_env=qs_env, rtp=rtp, matrix_s=s_mat, matrix_ks=matrix_ks, matrix_ks_im=matrix_ks_im, energy=energy)
      CALL get_rtp(rtp=rtp, exp_H_old=exp_H_old, exp_H_new=exp_H_new)

      IF (rtp_control%sc_check_start .LT. rtp%iter) THEN
         rtp%delta_iter_old = rtp%delta_iter
         IF (rtp%linear_scaling) THEN
            CALL rt_convergence_density(rtp, delta_P, rtp%delta_iter)
         ELSE
            CALL rt_convergence(rtp, s_mat(1)%matrix, delta_mos, rtp%delta_iter)
         END IF
         rtp%converged = (rtp%delta_iter .LT. rtp_control%eps_ener)
         !Apply mixing if scf loop is not converging

         !It would be better to redo the current step with mixixng,
         !but currently the decision is made to use mixing from the next step on
         IF (rtp_control%sc_check_start .LT. rtp%iter + 1) THEN
            IF (rtp%delta_iter/rtp%delta_iter_old > 0.9) THEN
               rtp%mixing_factor = MAX(rtp%mixing_factor/2.0_dp, 0.125_dp)
               rtp%mixing = .TRUE.
            END IF
         END IF
      END IF

      IF (rtp%converged) THEN
         IF (rtp%linear_scaling) THEN
            CALL get_rtp(rtp=rtp, rho_old=rho_old, rho_new=rho_new)
            CALL purify_mcweeny_complex_nonorth(rho_new, s_mat, rtp%filter_eps, rtp%filter_eps_small, &
                                                rtp_control%mcweeny_max_iter, rtp_control%mcweeny_eps)
            IF (rtp_control%mcweeny_max_iter > 0) CALL calc_update_rho_sparse(qs_env)
            CALL report_density_occupation(rtp%filter_eps, rho_new)
            DO i = 1, SIZE(rho_new)
               CALL dbcsr_copy(rho_old(i)%matrix, rho_new(i)%matrix)
            END DO
         ELSE
            CALL get_rtp(rtp=rtp, mos_old=mos_old, mos_new=mos_new)
            DO i = 1, SIZE(mos_new)
               CALL cp_fm_to_fm(mos_new(i), mos_old(i))
            END DO
         END IF
         IF (rtp_control%propagator == do_em) CALL calc_SinvH(rtp, matrix_ks, matrix_ks_im, rtp_control)
         DO i = 1, SIZE(exp_H_new)
            CALL dbcsr_copy(exp_H_old(i)%matrix, exp_H_new(i)%matrix)
         END DO
         ihist = MOD(rtp%istep, rtp_control%aspc_order) + 1
         IF (rtp_control%fixed_ions) THEN
            CALL put_data_to_history(rtp, rho=rho_new, mos=mos_new, ihist=ihist)
         ELSE
            CALL put_data_to_history(rtp, rho=rho_new, mos=mos_new, s_mat=s_mat, ihist=ihist)
         END IF
      END IF

      rtp%energy_new = energy%total

      CALL timestop(handle)

   END SUBROUTINE step_finalize

! **************************************************************************************************
!> \brief computes the propagator matrix for EM/ETRS, RTP/EMD
!> \param rtp ...
!> \param propagator ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE compute_propagator_matrix(rtp, propagator)
      TYPE(rt_prop_type), POINTER                        :: rtp
      INTEGER                                            :: propagator

      CHARACTER(len=*), PARAMETER :: routineN = 'compute_propagator_matrix'

      INTEGER                                            :: handle, i
      REAL(Kind=dp)                                      :: dt, prefac
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H_new, exp_H_old, propagator_matrix

      CALL timeset(routineN, handle)
      CALL get_rtp(rtp=rtp, exp_H_new=exp_H_new, exp_H_old=exp_H_old, &
                   propagator_matrix=propagator_matrix, dt=dt)

      prefac = -0.5_dp*dt

      DO i = 1, SIZE(exp_H_new)
         CALL dbcsr_add(propagator_matrix(i)%matrix, exp_H_new(i)%matrix, 0.0_dp, prefac)
         IF (propagator == do_em) &
            CALL dbcsr_add(propagator_matrix(i)%matrix, exp_H_old(i)%matrix, 1.0_dp, prefac)
      END DO

      CALL timestop(handle)

   END SUBROUTINE compute_propagator_matrix

! **************************************************************************************************
!> \brief computes t*S_inv*H, if needed t*Sinv*B
!> \param rtp ...
!> \param matrix_ks ...
!> \param matrix_ks_im ...
!> \param rtp_control ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE calc_SinvH(rtp, matrix_ks, matrix_ks_im, rtp_control)
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_ks, matrix_ks_im
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER                        :: routineN = 'calc_SinvH'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, im, ispin, re
      REAL(dp)                                           :: t
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H, SinvB, SinvH
      TYPE(dbcsr_type)                                   :: matrix_ks_nosym
      TYPE(dbcsr_type), POINTER                          :: B_mat, S_inv, S_minus_half

      CALL timeset(routineN, handle)
      CALL get_rtp(rtp=rtp, S_inv=S_inv, S_minus_half=S_minus_half, exp_H_new=exp_H, dt=t)
      CALL dbcsr_create(matrix_ks_nosym, template=matrix_ks(1)%matrix, matrix_type="N")
      DO ispin = 1, SIZE(matrix_ks)
         re = ispin*2 - 1
         im = ispin*2
         CALL dbcsr_desymmetrize(matrix_ks(ispin)%matrix, matrix_ks_nosym)
         CALL dbcsr_multiply("N", "N", one, S_inv, matrix_ks_nosym, zero, exp_H(im)%matrix, &
                             filter_eps=rtp%filter_eps)
         IF (.NOT. rtp_control%fixed_ions) THEN
            CALL get_rtp(rtp=rtp, SinvH=SinvH)
            CALL dbcsr_copy(SinvH(ispin)%matrix, exp_H(im)%matrix)
         END IF
      END DO
      IF (.NOT. rtp_control%fixed_ions .OR. rtp%do_hfx) THEN
         CALL get_rtp(rtp=rtp, B_mat=B_mat, SinvB=SinvB)
         IF (rtp%do_hfx) THEN
            DO ispin = 1, SIZE(matrix_ks)
               re = ispin*2 - 1
               im = ispin*2
               CALL dbcsr_set(matrix_ks_nosym, 0.0_dp)
               CALL dbcsr_desymmetrize(matrix_ks_im(ispin)%matrix, matrix_ks_nosym)

               ! take care of the EMD case and add the velocity scaled S_derivative
               IF (.NOT. rtp_control%fixed_ions) &
                  CALL dbcsr_add(matrix_ks_nosym, B_mat, 1.0_dp, -1.0_dp)

               CALL dbcsr_multiply("N", "N", -one, S_inv, matrix_ks_nosym, zero, exp_H(re)%matrix, &
                                   filter_eps=rtp%filter_eps)

               IF (.NOT. rtp_control%fixed_ions) &
                  CALL dbcsr_copy(SinvB(ispin)%matrix, exp_H(re)%matrix)
            END DO
         ELSE
            ! in case of pure EMD its only needed once as B is the same for both spins
            CALL dbcsr_multiply("N", "N", one, S_inv, B_mat, zero, exp_H(1)%matrix, filter_eps=rtp%filter_eps)

            CALL dbcsr_copy(SinvB(1)%matrix, exp_H(1)%matrix)

            IF (SIZE(matrix_ks) == 2) CALL dbcsr_copy(exp_H(3)%matrix, exp_H(1)%matrix)
            IF (SIZE(matrix_ks) == 2) CALL dbcsr_copy(SinvB(2)%matrix, SinvB(1)%matrix)
         END IF
      ELSE
         !set real part to zero
         DO ispin = 1, SIZE(exp_H)/2
            re = ispin*2 - 1
            im = ispin*2
            CALL dbcsr_set(exp_H(re)%matrix, zero)
         END DO
      END IF
      CALL dbcsr_release(matrix_ks_nosym)
      CALL timestop(handle)
   END SUBROUTINE calc_SinvH

! **************************************************************************************************
!> \brief calculates the needed overlap-like matrices
!>        depending on the way the exponential is calculated, only S^-1 is needed
!> \param s_mat ...
!> \param rtp ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE s_matrices_create(s_mat, rtp)

      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: s_mat
      TYPE(rt_prop_type), POINTER                        :: rtp

      CHARACTER(len=*), PARAMETER                        :: routineN = 's_matrices_create'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle
      TYPE(dbcsr_type), POINTER                          :: S_half, S_inv, S_minus_half

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, S_inv=S_inv)

      IF (rtp%linear_scaling) THEN
         CALL get_rtp(rtp=rtp, S_half=S_half, S_minus_half=S_minus_half)
         CALL matrix_sqrt_Newton_Schulz(S_half, S_minus_half, s_mat(1)%matrix, rtp%filter_eps, &
                                        rtp%newton_schulz_order, rtp%lanzcos_threshold, rtp%lanzcos_max_iter)
         CALL dbcsr_multiply("N", "N", one, S_minus_half, S_minus_half, zero, S_inv, &
                             filter_eps=rtp%filter_eps)
      ELSE
         CALL dbcsr_copy(S_inv, s_mat(1)%matrix)
         CALL cp_dbcsr_cholesky_decompose(S_inv, para_env=rtp%ao_ao_fmstruct%para_env, &
                                          blacs_env=rtp%ao_ao_fmstruct%context)
         CALL cp_dbcsr_cholesky_invert(S_inv, para_env=rtp%ao_ao_fmstruct%para_env, &
                                       blacs_env=rtp%ao_ao_fmstruct%context, upper_to_full=.TRUE.)
      END IF

      CALL timestop(handle)
   END SUBROUTINE s_matrices_create

! **************************************************************************************************
!> \brief Calculates the frobenius norm of a complex matrix represented by two real matrices
!> \param frob_norm ...
!> \param mat_re ...
!> \param mat_im ...
!> \author Samuel Andermatt (04.14)
! **************************************************************************************************

   SUBROUTINE complex_frobenius_norm(frob_norm, mat_re, mat_im)

      REAL(KIND=dp), INTENT(out)                         :: frob_norm
      TYPE(dbcsr_type), POINTER                          :: mat_re, mat_im

      CHARACTER(len=*), PARAMETER :: routineN = 'complex_frobenius_norm'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: col_atom, handle, row_atom
      LOGICAL                                            :: found
      REAL(dp), DIMENSION(:), POINTER                    :: block_values, block_values2
      TYPE(dbcsr_iterator_type)                          :: iter
      TYPE(dbcsr_type), POINTER                          :: tmp

      CALL timeset(routineN, handle)

      NULLIFY (tmp)
      ALLOCATE (tmp)
      CALL dbcsr_create(tmp, template=mat_re)
      !make sure the tmp has the same sparsity pattern as the real and the complex part combined
      CALL dbcsr_add(tmp, mat_re, zero, one)
      CALL dbcsr_add(tmp, mat_im, zero, one)
      CALL dbcsr_set(tmp, zero)
      !calculate the hadamard product
      CALL dbcsr_iterator_start(iter, tmp)
      DO WHILE (dbcsr_iterator_blocks_left(iter))
         CALL dbcsr_iterator_next_block(iter, row_atom, col_atom, block_values)
         CALL dbcsr_get_block_p(mat_re, row_atom, col_atom, block_values2, found=found)
         IF (found) THEN
            block_values = block_values2*block_values2
         END IF
         CALL dbcsr_get_block_p(mat_im, row_atom, col_atom, block_values2, found=found)
         IF (found) THEN
            block_values = block_values + block_values2*block_values2
         END IF
         block_values = SQRT(block_values)
      END DO
      CALL dbcsr_iterator_stop(iter)
      frob_norm = dbcsr_frobenius_norm(tmp)

      CALL dbcsr_deallocate_matrix(tmp)

      CALL timestop(handle)

   END SUBROUTINE complex_frobenius_norm

! **************************************************************************************************
!> \brief Does McWeeny for complex matrices in the non-orthogonal basis
!> \param P ...
!> \param s_mat ...
!> \param eps ...
!> \param eps_small ...
!> \param max_iter ...
!> \param threshold ...
!> \author Samuel Andermatt (04.14)
! **************************************************************************************************

   SUBROUTINE purify_mcweeny_complex_nonorth(P, s_mat, eps, eps_small, max_iter, threshold)

      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: P, s_mat
      REAL(KIND=dp), INTENT(in)                          :: eps, eps_small
      INTEGER, INTENT(in)                                :: max_iter
      REAL(KIND=dp), INTENT(in)                          :: threshold

      CHARACTER(len=*), PARAMETER :: routineN = 'purify_mcweeny_complex_nonorth'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, im, imax, ispin, re, unit_nr
      REAL(KIND=dp)                                      :: frob_norm
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: PS, PSP, tmp

      CALL timeset(routineN, handle)

      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      NULLIFY (tmp, PS, PSP)
      CALL dbcsr_allocate_matrix_set(tmp, SIZE(P))
      CALL dbcsr_allocate_matrix_set(PSP, SIZE(P))
      CALL dbcsr_allocate_matrix_set(PS, SIZE(P))
      DO i = 1, SIZE(P)
         CALL dbcsr_init_p(PS(i)%matrix)
         CALL dbcsr_create(PS(i)%matrix, template=P(1)%matrix)
         CALL dbcsr_init_p(PSP(i)%matrix)
         CALL dbcsr_create(PSP(i)%matrix, template=P(1)%matrix)
         CALL dbcsr_init_p(tmp(i)%matrix)
         CALL dbcsr_create(tmp(i)%matrix, template=P(1)%matrix)
      END DO
      IF (SIZE(P) == 2) THEN
         CALL dbcsr_scale(P(1)%matrix, one/2)
         CALL dbcsr_scale(P(2)%matrix, one/2)
      END IF
      DO ispin = 1, SIZE(P)/2
         re = 2*ispin - 1
         im = 2*ispin
         imax = MAX(max_iter, 1) !if max_iter is 0 then only the deviation from idempotency needs to be calculated
         DO i = 1, imax
            CALL dbcsr_multiply("N", "N", one, P(re)%matrix, s_mat(1)%matrix, &
                                zero, PS(re)%matrix, filter_eps=eps_small)
            CALL dbcsr_multiply("N", "N", one, P(im)%matrix, s_mat(1)%matrix, &
                                zero, PS(im)%matrix, filter_eps=eps_small)
            CALL cp_complex_dbcsr_gemm_3("N", "N", one, PS(re)%matrix, PS(im)%matrix, &
                                         P(re)%matrix, P(im)%matrix, zero, PSP(re)%matrix, PSP(im)%matrix, &
                                         filter_eps=eps_small)
            CALL dbcsr_copy(tmp(re)%matrix, PSP(re)%matrix)
            CALL dbcsr_copy(tmp(im)%matrix, PSP(im)%matrix)
            CALL dbcsr_add(tmp(re)%matrix, P(re)%matrix, 1.0_dp, -1.0_dp)
            CALL dbcsr_add(tmp(im)%matrix, P(im)%matrix, 1.0_dp, -1.0_dp)
            CALL complex_frobenius_norm(frob_norm, tmp(re)%matrix, tmp(im)%matrix)
            IF (unit_nr .GT. 0) WRITE (unit_nr, '(t3,a,2f16.8)') "Deviation from idempotency: ", frob_norm
            IF (frob_norm .GT. threshold .AND. max_iter > 0) THEN
               CALL dbcsr_copy(P(re)%matrix, PSP(re)%matrix)
               CALL dbcsr_copy(P(im)%matrix, PSP(im)%matrix)
               CALL cp_complex_dbcsr_gemm_3("N", "N", -2.0_dp, PS(re)%matrix, PS(im)%matrix, &
                                            PSP(re)%matrix, PSP(im)%matrix, 3.0_dp, P(re)%matrix, P(im)%matrix, &
                                            filter_eps=eps_small)
               CALL dbcsr_filter(P(re)%matrix, eps)
               CALL dbcsr_filter(P(im)%matrix, eps)
               !make sure P is exactly hermitian
               CALL dbcsr_transposed(tmp(re)%matrix, P(re)%matrix)
               CALL dbcsr_add(P(re)%matrix, tmp(re)%matrix, one/2, one/2)
               CALL dbcsr_transposed(tmp(im)%matrix, P(im)%matrix)
               CALL dbcsr_add(P(im)%matrix, tmp(im)%matrix, one/2, -one/2)
            ELSE
               EXIT
            END IF
         END DO
         !make sure P is hermitian
         CALL dbcsr_transposed(tmp(re)%matrix, P(re)%matrix)
         CALL dbcsr_add(P(re)%matrix, tmp(re)%matrix, one/2, one/2)
         CALL dbcsr_transposed(tmp(im)%matrix, P(im)%matrix)
         CALL dbcsr_add(P(im)%matrix, tmp(im)%matrix, one/2, -one/2)
      END DO
      IF (SIZE(P) == 2) THEN
         CALL dbcsr_scale(P(1)%matrix, one*2)
         CALL dbcsr_scale(P(2)%matrix, one*2)
      END IF
      CALL dbcsr_deallocate_matrix_set(tmp)
      CALL dbcsr_deallocate_matrix_set(PS)
      CALL dbcsr_deallocate_matrix_set(PSP)

      CALL timestop(handle)

   END SUBROUTINE purify_mcweeny_complex_nonorth

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
!> \param matrix_s ...
!> \param aspc_order ...
! **************************************************************************************************
   SUBROUTINE aspc_extrapolate(rtp, matrix_s, aspc_order)
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      INTEGER, INTENT(in)                                :: aspc_order

      CHARACTER(len=*), PARAMETER                        :: routineN = 'aspc_extrapolate'
      COMPLEX(KIND=dp), PARAMETER                        :: cone = (1.0_dp, 0.0_dp), &
                                                            czero = (0.0_dp, 0.0_dp)
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, iaspc, icol_local, ihist, &
                                                            imat, k, kdbl, n, naspc, ncol_local, &
                                                            nmat
      REAL(KIND=dp)                                      :: alpha
      TYPE(cp_cfm_type)                                  :: cfm_tmp, cfm_tmp1, csc
      TYPE(cp_fm_struct_type), POINTER                   :: matrix_struct, matrix_struct_new
      TYPE(cp_fm_type)                                   :: fm_tmp, fm_tmp1, fm_tmp2
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: mos_new
      TYPE(cp_fm_type), DIMENSION(:, :), POINTER         :: mo_hist
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_new, s_hist
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: rho_hist

      NULLIFY (rho_hist)
      CALL timeset(routineN, handle)
      CALL cite_reference(Kolafa2004)
      CALL cite_reference(Kuhne2007)

      IF (rtp%linear_scaling) THEN
         CALL get_rtp(rtp=rtp, rho_new=rho_new)
      ELSE
         CALL get_rtp(rtp=rtp, mos_new=mos_new)
      END IF

      naspc = MIN(rtp%istep, aspc_order)
      IF (rtp%linear_scaling) THEN
         nmat = SIZE(rho_new)
         rho_hist => rtp%history%rho_history
         DO imat = 1, nmat
            DO iaspc = 1, naspc
               alpha = (-1.0_dp)**(iaspc + 1)*REAL(iaspc, KIND=dp)* &
                       binomial(2*naspc, naspc - iaspc)/binomial(2*naspc - 2, naspc - 1)
               ihist = MOD(rtp%istep - iaspc, aspc_order) + 1
               IF (iaspc == 1) THEN
                  CALL dbcsr_add(rho_new(imat)%matrix, rho_hist(imat, ihist)%matrix, zero, alpha)
               ELSE
                  CALL dbcsr_add(rho_new(imat)%matrix, rho_hist(imat, ihist)%matrix, one, alpha)
               END IF
            END DO
         END DO
      ELSE
         mo_hist => rtp%history%mo_history
         nmat = SIZE(mos_new)
         DO imat = 1, nmat
            DO iaspc = 1, naspc
               alpha = (-1.0_dp)**(iaspc + 1)*REAL(iaspc, KIND=dp)* &
                       binomial(2*naspc, naspc - iaspc)/binomial(2*naspc - 2, naspc - 1)
               ihist = MOD(rtp%istep - iaspc, aspc_order) + 1
               IF (iaspc == 1) THEN
                  CALL cp_fm_scale_and_add(zero, mos_new(imat), alpha, mo_hist(imat, ihist))
               ELSE
                  CALL cp_fm_scale_and_add(one, mos_new(imat), alpha, mo_hist(imat, ihist))
               END IF
            END DO
         END DO

         mo_hist => rtp%history%mo_history
         s_hist => rtp%history%s_history
         DO i = 1, SIZE(mos_new)/2
            NULLIFY (matrix_struct, matrix_struct_new)

            CALL cp_fm_struct_double(matrix_struct, &
                                     mos_new(2*i)%matrix_struct, &
                                     mos_new(2*i)%matrix_struct%context, &
                                     .TRUE., .FALSE.)

            CALL cp_fm_create(fm_tmp, matrix_struct)
            CALL cp_fm_create(fm_tmp1, matrix_struct)
            CALL cp_fm_create(fm_tmp2, mos_new(2*i)%matrix_struct)
            CALL cp_cfm_create(cfm_tmp, mos_new(2*i)%matrix_struct)
            CALL cp_cfm_create(cfm_tmp1, mos_new(2*i)%matrix_struct)

            CALL cp_fm_get_info(fm_tmp, ncol_global=kdbl)

            CALL cp_fm_get_info(mos_new(2*i), &
                                nrow_global=n, &
                                ncol_global=k, &
                                ncol_local=ncol_local)

            CALL cp_fm_struct_create(matrix_struct_new, &
                                     template_fmstruct=mos_new(2*i)%matrix_struct, &
                                     nrow_global=k, &
                                     ncol_global=k)
            CALL cp_cfm_create(csc, matrix_struct_new)

            CALL cp_fm_struct_release(matrix_struct_new)
            CALL cp_fm_struct_release(matrix_struct)

            ! first the most recent

! reorthogonalize vectors
            DO icol_local = 1, ncol_local
               fm_tmp%local_data(:, icol_local) = mos_new(2*i - 1)%local_data(:, icol_local)
               fm_tmp%local_data(:, icol_local + ncol_local) = mos_new(2*i)%local_data(:, icol_local)
            END DO

            CALL cp_dbcsr_sm_fm_multiply(matrix_s(1)%matrix, fm_tmp, fm_tmp1, kdbl)

            DO icol_local = 1, ncol_local
               cfm_tmp%local_data(:, icol_local) = CMPLX(fm_tmp1%local_data(:, icol_local), &
                                                         fm_tmp1%local_data(:, icol_local + ncol_local), dp)
               cfm_tmp1%local_data(:, icol_local) = CMPLX(mos_new(2*i - 1)%local_data(:, icol_local), &
                                                          mos_new(2*i)%local_data(:, icol_local), dp)
            END DO
            CALL parallel_gemm('C', 'N', k, k, n, cone, cfm_tmp1, cfm_tmp, czero, csc)
            CALL cp_cfm_cholesky_decompose(csc)
            CALL cp_cfm_triangular_multiply(csc, cfm_tmp1, n_cols=k, side='R', invert_tr=.TRUE.)
            DO icol_local = 1, ncol_local
               mos_new(2*i - 1)%local_data(:, icol_local) = REAL(cfm_tmp1%local_data(:, icol_local), dp)
               mos_new(2*i)%local_data(:, icol_local) = AIMAG(cfm_tmp1%local_data(:, icol_local))
            END DO

! deallocate work matrices
            CALL cp_cfm_release(csc)
            CALL cp_fm_release(fm_tmp)
            CALL cp_fm_release(fm_tmp1)
            CALL cp_fm_release(fm_tmp2)
            CALL cp_cfm_release(cfm_tmp)
            CALL cp_cfm_release(cfm_tmp1)
         END DO

      END IF

      CALL timestop(handle)

   END SUBROUTINE aspc_extrapolate

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
!> \param mos ...
!> \param rho ...
!> \param s_mat ...
!> \param ihist ...
! **************************************************************************************************
   SUBROUTINE put_data_to_history(rtp, mos, rho, s_mat, ihist)
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: mos
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho
      TYPE(dbcsr_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: s_mat
      INTEGER                                            :: ihist

      INTEGER                                            :: i

      IF (rtp%linear_scaling) THEN
         DO i = 1, SIZE(rho)
            CALL dbcsr_copy(rtp%history%rho_history(i, ihist)%matrix, rho(i)%matrix)
         END DO
      ELSE
         DO i = 1, SIZE(mos)
            CALL cp_fm_to_fm(mos(i), rtp%history%mo_history(i, ihist))
         END DO
         IF (PRESENT(s_mat)) THEN
            IF (ASSOCIATED(rtp%history%s_history(ihist)%matrix)) THEN ! the sparsity might be different
               ! (future struct:check)
               CALL dbcsr_deallocate_matrix(rtp%history%s_history(ihist)%matrix)
            END IF
            ALLOCATE (rtp%history%s_history(ihist)%matrix)
            CALL dbcsr_copy(rtp%history%s_history(ihist)%matrix, s_mat(1)%matrix)
         END IF
      END IF

   END SUBROUTINE put_data_to_history

END MODULE rt_propagation_methods
