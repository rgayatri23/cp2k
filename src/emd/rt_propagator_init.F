!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines for that prepare rtp and EMD
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************
MODULE rt_propagator_init

   USE arnoldi_api,                     ONLY: arnoldi_extremal
   USE cp_control_types,                ONLY: dft_control_type,&
                                              rtp_control_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr,&
                                              cp_dbcsr_plus_fm_fm_t
   USE cp_fm_basic_linalg,              ONLY: cp_fm_column_scale,&
                                              cp_fm_scale,&
                                              cp_fm_upper_to_full
   USE cp_fm_diag,                      ONLY: cp_fm_syevd
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_release,&
                                              cp_fm_set_all,&
                                              cp_fm_to_fm,&
                                              cp_fm_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type
   USE dbcsr_api,                       ONLY: &
        dbcsr_copy, dbcsr_create, dbcsr_deallocate_matrix, dbcsr_filter, dbcsr_multiply, &
        dbcsr_p_type, dbcsr_scale, dbcsr_set, dbcsr_type
   USE input_constants,                 ONLY: do_arnoldi,&
                                              do_bch,&
                                              do_cn,&
                                              do_em,&
                                              do_etrs,&
                                              do_pade,&
                                              do_taylor
   USE iterate_matrix,                  ONLY: matrix_sqrt_Newton_Schulz
   USE kinds,                           ONLY: dp
   USE matrix_exp,                      ONLY: get_nsquare_norder
   USE parallel_gemm_api,               ONLY: parallel_gemm
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_mo_types,                     ONLY: mo_set_type
   USE rt_make_propagators,             ONLY: compute_exponential,&
                                              compute_exponential_sparse,&
                                              propagate_arnoldi
   USE rt_propagation_methods,          ONLY: calc_SinvH,&
                                              put_data_to_history,&
                                              s_matrices_create
   USE rt_propagation_types,            ONLY: get_rtp,&
                                              rt_prop_type
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_propagator_init'

   PUBLIC :: init_propagators, &
             rt_initialize_rho_from_mos

CONTAINS

! **************************************************************************************************
!> \brief prepares the initial matrices for the propagators
!> \param qs_env ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE init_propagators(qs_env)

      TYPE(qs_environment_type), POINTER                 :: qs_env

      INTEGER                                            :: i, imat, unit_nr
      REAL(KIND=dp)                                      :: dt, prefac
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: mos_new, mos_next, mos_old
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H_new, exp_H_old, matrix_ks, &
                                                            matrix_ks_im, propagator_matrix, &
                                                            rho_old, s_mat
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CALL get_qs_env(qs_env, &
                      rtp=rtp, &
                      dft_control=dft_control, &
                      matrix_s=s_mat, &
                      matrix_ks=matrix_ks, &
                      matrix_ks_im=matrix_ks_im)

      rtp_control => dft_control%rtp_control
      CALL get_rtp(rtp=rtp, exp_H_old=exp_H_old, exp_H_new=exp_H_new, &
                   propagator_matrix=propagator_matrix, dt=dt)
      CALL s_matrices_create(s_mat, rtp)
      CALL calc_SinvH(rtp, matrix_ks, matrix_ks_im, rtp_control)
      DO i = 1, SIZE(exp_H_old)
         CALL dbcsr_copy(exp_H_old(i)%matrix, exp_H_new(i)%matrix)
      END DO
      ! use the fact that CN propagator is a first order pade approximation on the EM propagator
      IF (rtp_control%propagator == do_cn) THEN
         rtp%orders(1, :) = 0; rtp%orders(2, :) = 1; rtp_control%mat_exp = do_pade; rtp_control%propagator = do_em
      ELSE IF (rtp_control%mat_exp == do_pade .OR. rtp_control%mat_exp == do_taylor) THEN
         IF (rtp%linear_scaling) THEN
            CALL get_maxabs_eigval_sparse(rtp, s_mat, matrix_ks, rtp_control)
         ELSE
            CALL get_maxabs_eigval(rtp, s_mat, matrix_ks, rtp_control)
         END IF
      END IF
      IF (rtp_control%mat_exp == do_pade .AND. rtp%linear_scaling) THEN
         ! get a useful output_unit
         logger => cp_get_default_logger()
         IF (logger%para_env%ionode) THEN
            unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
            WRITE (unit_nr, *) "linear_scaling currently does not support pade exponentials, switching to taylor"
         END IF
         rtp_control%mat_exp = do_taylor
      END IF
      ! We have no clue yet about next H so we use initial H for t and t+dt
      ! Due to different nature of the propagator the prefactor has to be adopted
      SELECT CASE (rtp_control%propagator)
      CASE (do_etrs)
         prefac = -0.5_dp*dt
      CASE (do_em)
         prefac = -1.0_dp*dt
      END SELECT
      DO imat = 1, SIZE(exp_H_new)
         CALL dbcsr_copy(propagator_matrix(imat)%matrix, exp_H_new(imat)%matrix)
         CALL dbcsr_scale(propagator_matrix(imat)%matrix, prefac)
      END DO

      ! For ETRS this bit could be avoided but it drastically simplifies the workflow afterwards.
      ! If we compute the half propagated mos/exponential already here, we ensure everything is done
      ! with the correct S matrix and all information as during RTP/EMD are computed.
      ! Therefore we might accept to compute an unnesscesary exponential but understand the code afterwards
      IF (rtp_control%propagator == do_etrs) THEN
         IF (rtp_control%mat_exp == do_arnoldi) THEN
            rtp%iter = 0
            CALL propagate_arnoldi(rtp, rtp_control)
            CALL get_rtp(rtp=rtp, mos_new=mos_new, mos_next=mos_next)
            DO imat = 1, SIZE(mos_new)
               CALL cp_fm_to_fm(mos_new(imat), mos_next(imat))
            END DO
         ELSEIF (rtp_control%mat_exp == do_bch) THEN
         ELSE
            IF (rtp%linear_scaling) THEN
               CALL compute_exponential_sparse(exp_H_new, propagator_matrix, rtp_control, rtp)
            ELSE
               CALL compute_exponential(exp_H_new, propagator_matrix, rtp_control, rtp)
            END IF
            DO imat = 1, SIZE(exp_H_new)
               CALL dbcsr_copy(exp_H_old(imat)%matrix, exp_H_new(imat)%matrix)
            END DO
         END IF
      END IF

      IF (rtp%linear_scaling) THEN
         CALL get_rtp(rtp=rtp, rho_old=rho_old)
      ELSE
         CALL get_rtp(rtp=rtp, mos_old=mos_old)
      END IF
      CALL put_data_to_history(rtp, mos=mos_old, s_mat=s_mat, ihist=1, rho=rho_old)

   END SUBROUTINE init_propagators

! **************************************************************************************************
!> \brief gets an estimate for the 2-norm of KS (diagnaliztion of KS) and
!>        calculates the order and number of squaring steps for Taylor or
!>        Pade matrix exponential
!> \param rtp ...
!> \param s_mat ...
!> \param matrix_ks ...
!> \param rtp_control ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE get_maxabs_eigval(rtp, s_mat, matrix_ks, rtp_control)
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: s_mat, matrix_ks
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER                        :: routineN = 'get_maxabs_eigval'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, ispin, method, ndim
      LOGICAL                                            :: emd
      REAL(dp)                                           :: max_eval, min_eval, norm2, scale, t
      REAL(dp), ALLOCATABLE, DIMENSION(:)                :: eigval_H
      TYPE(cp_fm_type)                                   :: eigvec_H, H_fm, S_half, S_inv_fm, &
                                                            S_minus_half, tmp, tmp_mat_H
      TYPE(dbcsr_type), POINTER                          :: S_inv

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, S_inv=S_inv, dt=t)

      CALL cp_fm_create(S_inv_fm, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="S_inv")
      CALL copy_dbcsr_to_fm(S_inv, S_inv_fm)

      CALL cp_fm_create(S_half, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="S_half")

      CALL cp_fm_create(S_minus_half, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="S_minus_half")

      CALL cp_fm_create(H_fm, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="RTP_H_FM")

      CALL cp_fm_create(tmp_mat_H, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="TMP_H")

      ndim = S_inv_fm%matrix_struct%nrow_global
      scale = 1.0_dp
      IF (rtp_control%propagator == do_etrs) scale = 2.0_dp
      t = -t/scale

      ! Create the overlap matrices

      CALL cp_fm_create(tmp, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="tmp_mat")

      CALL cp_fm_create(eigvec_H, &
                        matrix_struct=rtp%ao_ao_fmstruct, &
                        name="tmp_EVEC")

      ALLOCATE (eigval_H(ndim))
      CALL copy_dbcsr_to_fm(s_mat(1)%matrix, tmp)
      CALL cp_fm_upper_to_full(tmp, eigvec_H)

      CALL cp_fm_syevd(tmp, eigvec_H, eigval_H)

      eigval_H(:) = one/eigval_H(:)
      CALL backtransform_matrix(eigval_H, eigvec_H, S_inv_fm)
      eigval_H(:) = SQRT(eigval_H(:))
      CALL backtransform_matrix(eigval_H, eigvec_H, S_minus_half)
      eigval_H(:) = one/eigval_H(:)
      CALL backtransform_matrix(eigval_H, eigvec_H, S_half)
      CALL cp_fm_release(eigvec_H)
      CALL cp_fm_release(tmp)

      IF (rtp_control%mat_exp == do_taylor) method = 1
      IF (rtp_control%mat_exp == do_pade) method = 2
      emd = (.NOT. rtp_control%fixed_ions)

      DO ispin = 1, SIZE(matrix_ks)

         CALL copy_dbcsr_to_fm(matrix_ks(ispin)%matrix, H_fm)
         CALL cp_fm_upper_to_full(H_fm, tmp_mat_H)
         CALL cp_fm_scale(t, H_fm)

         CALL parallel_gemm("N", "N", ndim, ndim, ndim, one, H_fm, S_minus_half, zero, &
                            tmp_mat_H)
         CALL parallel_gemm("N", "N", ndim, ndim, ndim, one, S_minus_half, tmp_mat_H, zero, &
                            H_fm)

         CALL cp_fm_syevd(H_fm, tmp_mat_H, eigval_H)
         min_eval = MINVAL(eigval_H)
         max_eval = MAXVAL(eigval_H)
         norm2 = 2.0_dp*MAX(ABS(min_eval), ABS(max_eval))
         CALL get_nsquare_norder(norm2, rtp%orders(1, ispin), rtp%orders(2, ispin), &
                                 rtp_control%eps_exp, method, emd)
      END DO

      DEALLOCATE (eigval_H)

      CALL copy_fm_to_dbcsr(S_inv_fm, S_inv)
      CALL cp_fm_release(S_inv_fm)
      CALL cp_fm_release(S_half)
      CALL cp_fm_release(S_minus_half)
      CALL cp_fm_release(H_fm)
      CALL cp_fm_release(tmp_mat_H)

      CALL timestop(handle)

   END SUBROUTINE get_maxabs_eigval

! **************************************************************************************************
!> \brief gets an estimate for the 2-norm of KS (diagnaliztion of KS) and
!>        calculates the order and number of squaring steps for Taylor or
!>        Pade matrix exponential. Based on the full matrix code.
!> \param rtp ...
!> \param s_mat ...
!> \param matrix_ks ...
!> \param rtp_control ...
!> \author Samuel Andermatt (02.14)
! **************************************************************************************************

   SUBROUTINE get_maxabs_eigval_sparse(rtp, s_mat, matrix_ks, rtp_control)
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: s_mat, matrix_ks
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER :: routineN = 'get_maxabs_eigval_sparse'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, ispin, method
      LOGICAL                                            :: converged, emd
      REAL(dp)                                           :: max_ev, min_ev, norm2, scale, t
      TYPE(dbcsr_type), POINTER                          :: s_half, s_minus_half, tmp, tmp2

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, dt=t)

      NULLIFY (s_half)
      ALLOCATE (s_half)
      CALL dbcsr_create(s_half, template=s_mat(1)%matrix)
      NULLIFY (s_minus_half)
      ALLOCATE (s_minus_half)
      CALL dbcsr_create(s_minus_half, template=s_mat(1)%matrix)
      NULLIFY (tmp)
      ALLOCATE (tmp)
      CALL dbcsr_create(tmp, template=s_mat(1)%matrix, matrix_type="N")
      NULLIFY (tmp2)
      ALLOCATE (tmp2)
      CALL dbcsr_create(tmp2, template=s_mat(1)%matrix, matrix_type="N")
      scale = 1.0_dp
      IF (rtp_control%propagator == do_etrs) scale = 2.0_dp
      t = -t/scale
      emd = (.NOT. rtp_control%fixed_ions)

      IF (rtp_control%mat_exp == do_taylor) method = 1
      IF (rtp_control%mat_exp == do_pade) method = 2
      CALL matrix_sqrt_Newton_Schulz(s_half, s_minus_half, s_mat(1)%matrix, rtp%filter_eps, &
                                     rtp%newton_schulz_order, rtp%lanzcos_threshold, rtp%lanzcos_max_iter)
      DO ispin = 1, SIZE(matrix_ks)
         CALL dbcsr_multiply("N", "N", t, matrix_ks(ispin)%matrix, s_minus_half, zero, tmp, &
                             filter_eps=rtp%filter_eps)
         CALL dbcsr_multiply("N", "N", one, s_minus_half, tmp, zero, tmp2, &
                             filter_eps=rtp%filter_eps)
         CALL arnoldi_extremal(tmp2, max_ev, min_ev, threshold=rtp%lanzcos_threshold, &
                               max_iter=rtp%lanzcos_max_iter, converged=converged)
         norm2 = 2.0_dp*MAX(ABS(min_ev), ABS(max_ev))
         CALL get_nsquare_norder(norm2, rtp%orders(1, ispin), rtp%orders(2, ispin), &
                                 rtp_control%eps_exp, method, emd)
      END DO

      CALL dbcsr_deallocate_matrix(s_half)
      CALL dbcsr_deallocate_matrix(s_minus_half)
      CALL dbcsr_deallocate_matrix(tmp)
      CALL dbcsr_deallocate_matrix(tmp2)

      CALL timestop(handle)

   END SUBROUTINE

! **************************************************************************************************
!> \brief Is still left from diagonalization, should be removed later but is
!>  still needed for the guess for the pade/Taylor method
!> \param Eval ...
!> \param eigenvec ...
!> \param matrix ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE backtransform_matrix(Eval, eigenvec, matrix)

      REAL(dp), DIMENSION(:), INTENT(in)                 :: Eval
      TYPE(cp_fm_type), INTENT(IN)                       :: eigenvec, matrix

      CHARACTER(len=*), PARAMETER :: routineN = 'backtransform_matrix'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, j, l, ncol_local, ndim, &
                                                            nrow_local
      INTEGER, DIMENSION(:), POINTER                     :: col_indices, row_indices
      TYPE(cp_fm_type)                                   :: tmp

      CALL timeset(routineN, handle)
      CALL cp_fm_create(tmp, &
                        matrix_struct=matrix%matrix_struct, &
                        name="TMP_BT")
      CALL cp_fm_get_info(matrix, nrow_local=nrow_local, ncol_local=ncol_local, &
                          row_indices=row_indices, col_indices=col_indices)

      ndim = matrix%matrix_struct%nrow_global

      CALL cp_fm_set_all(tmp, zero, zero)
      DO i = 1, ncol_local
         l = col_indices(i)
         DO j = 1, nrow_local
            tmp%local_data(j, i) = eigenvec%local_data(j, i)*Eval(l)
         END DO
      END DO
      CALL parallel_gemm("N", "T", ndim, ndim, ndim, one, tmp, eigenvec, zero, &
                         matrix)

      CALL cp_fm_release(tmp)
      CALL timestop(handle)

   END SUBROUTINE backtransform_matrix

! **************************************************************************************************
!> \brief Computes the density matrix from the mos
!> \param rtp ...
!> \param mos ...
!> \author Samuel Andermatt (08.15)
! **************************************************************************************************

   SUBROUTINE rt_initialize_rho_from_mos(rtp, mos)

      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos

      INTEGER                                            :: ispin, ncol, re
      REAL(KIND=dp)                                      :: alpha
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_new, rho_old

      CALL get_rtp(rtp=rtp, rho_old=rho_old, rho_new=rho_new)

      DO ispin = 1, SIZE(mos)
         re = 2*ispin - 1
         alpha = 3.0_dp - REAL(SIZE(mos), dp)
         CALL dbcsr_set(rho_old(re)%matrix, 0.0_dp)
         CALL cp_fm_get_info(mos(ispin)%mo_coeff, ncol_global=ncol)
         CALL cp_fm_column_scale(mos(ispin)%mo_coeff, mos(ispin)%occupation_numbers/alpha)
         CALL cp_dbcsr_plus_fm_fm_t(sparse_matrix=rho_old(re)%matrix, &
                                    matrix_v=mos(ispin)%mo_coeff, ncol=ncol, alpha=alpha, keep_sparsity=.FALSE.)
         CALL dbcsr_filter(rho_old(re)%matrix, rtp%filter_eps)
         CALL dbcsr_copy(rho_new(re)%matrix, rho_old(re)%matrix)
      END DO

   END SUBROUTINE rt_initialize_rho_from_mos

END MODULE rt_propagator_init
