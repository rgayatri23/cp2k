!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines for calculating a complex matrix exponential.
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

MODULE rt_make_propagators

   USE cp_control_types,                ONLY: rtp_control_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr,&
                                              cp_dbcsr_sm_fm_multiply
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_to_fm,&
                                              cp_fm_type
   USE cp_fm_vect,                      ONLY: cp_fm_vect_dealloc
   USE dbcsr_api,                       ONLY: dbcsr_copy,&
                                              dbcsr_create,&
                                              dbcsr_deallocate_matrix,&
                                              dbcsr_p_type,&
                                              dbcsr_scale,&
                                              dbcsr_type
   USE input_constants,                 ONLY: do_etrs,&
                                              do_pade,&
                                              do_taylor
   USE kinds,                           ONLY: dp
   USE ls_matrix_exp,                   ONLY: bch_expansion_complex_propagator,&
                                              bch_expansion_imaginary_propagator,&
                                              cp_complex_dbcsr_gemm_3,&
                                              taylor_full_complex_dbcsr,&
                                              taylor_only_imaginary_dbcsr
   USE matrix_exp,                      ONLY: arnoldi,&
                                              exp_pade_full_complex,&
                                              exp_pade_only_imaginary,&
                                              taylor_full_complex,&
                                              taylor_only_imaginary
   USE rt_propagation_types,            ONLY: get_rtp,&
                                              rt_prop_type
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_make_propagators'

   PUBLIC :: propagate_exp, &
             propagate_arnoldi, &
             compute_exponential, &
             compute_exponential_sparse, &
             propagate_exp_density, &
             propagate_bch

CONTAINS
! **************************************************************************************************
!> \brief performs propagations if explicit matrix exponentials are used
!>        ETRS:  exp(i*H(t+dt)*dt/2)*exp(i*H(t)*dt/2)*MOS
!>        EM:    exp[-idt/2H(t+dt/2)*MOS
!> \param rtp ...
!> \param rtp_control ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE propagate_exp(rtp, rtp_control)

      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER                        :: routineN = 'propagate_exp'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, im, nmo, re
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: mos_new, mos_next, mos_old
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H_new, exp_H_old, propagator_matrix

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, propagator_matrix=propagator_matrix, mos_old=mos_old, mos_new=mos_new, &
                   mos_next=mos_next, exp_H_new=exp_H_new, exp_H_old=exp_H_old)

      ! Only compute exponential if a new propagator matrix is available
      CALL compute_exponential(exp_H_new, propagator_matrix, rtp_control, rtp)

      DO i = 1, SIZE(mos_new)/2
         re = 2*i - 1
         im = 2*i

         CALL cp_fm_get_info(mos_new(re), ncol_global=nmo)
         !Save some work by computing the first half of the propagation only once in case of ETRS
         !For EM this matrix has to be the initial matrix, thus a copy is enough
         IF (rtp%iter == 1) THEN
            IF (rtp_control%propagator == do_etrs) THEN
               CALL cp_dbcsr_sm_fm_multiply(exp_H_old(re)%matrix, mos_old(re), &
                                            mos_next(re), nmo, alpha=one, beta=zero)
               CALL cp_dbcsr_sm_fm_multiply(exp_H_old(im)%matrix, mos_old(im), &
                                            mos_next(re), nmo, alpha=-one, beta=one)
               CALL cp_dbcsr_sm_fm_multiply(exp_H_old(re)%matrix, mos_old(im), &
                                            mos_next(im), nmo, alpha=one, beta=zero)
               CALL cp_dbcsr_sm_fm_multiply(exp_H_old(im)%matrix, mos_old(re), &
                                            mos_next(im), nmo, alpha=one, beta=one)
            ELSE
               CALL cp_fm_to_fm(mos_old(re), mos_next(re))
               CALL cp_fm_to_fm(mos_old(im), mos_next(im))
            END IF
         END IF
         CALL cp_dbcsr_sm_fm_multiply(exp_H_new(re)%matrix, mos_next(re), &
                                      mos_new(re), nmo, alpha=one, beta=zero)
         CALL cp_dbcsr_sm_fm_multiply(exp_H_new(im)%matrix, mos_next(im), &
                                      mos_new(re), nmo, alpha=-one, beta=one)
         CALL cp_dbcsr_sm_fm_multiply(exp_H_new(re)%matrix, mos_next(im), &
                                      mos_new(im), nmo, alpha=one, beta=zero)
         CALL cp_dbcsr_sm_fm_multiply(exp_H_new(im)%matrix, mos_next(re), &
                                      mos_new(im), nmo, alpha=one, beta=one)
      END DO

      CALL timestop(handle)

   END SUBROUTINE propagate_exp

! **************************************************************************************************
!> \brief Propagation of the density matrix instead of the atomic orbitals
!>        via a matrix exponential
!> \param rtp ...
!> \param rtp_control ...
!> \author Samuel Andermatt (02.2014)
! **************************************************************************************************

   SUBROUTINE propagate_exp_density(rtp, rtp_control)

      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER :: routineN = 'propagate_exp_density'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, im, re
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H_new, exp_H_old, propagator_matrix, &
                                                            rho_new, rho_next, rho_old
      TYPE(dbcsr_type), POINTER                          :: tmp_im, tmp_re

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, propagator_matrix=propagator_matrix, exp_H_new=exp_H_new, &
                   exp_H_old=exp_H_old, rho_old=rho_old, rho_new=rho_new, rho_next=rho_next)

      CALL compute_exponential_sparse(exp_H_new, propagator_matrix, rtp_control, rtp)

      !I could store these matrices in the type
      NULLIFY (tmp_re)
      ALLOCATE (tmp_re)
      CALL dbcsr_create(tmp_re, template=propagator_matrix(1)%matrix, matrix_type="N")
      NULLIFY (tmp_im)
      ALLOCATE (tmp_im)
      CALL dbcsr_create(tmp_im, template=propagator_matrix(1)%matrix, matrix_type="N")

      DO i = 1, SIZE(exp_H_new)/2
         re = 2*i - 1
         im = 2*i
         !Save some work by computing the first half of the propagation only once in case of ETRS
         !For EM this matrix has to be the initial matrix, thus a copy is enough
         IF (rtp%iter == 1) THEN
            IF (rtp_control%propagator == do_etrs) THEN
               CALL cp_complex_dbcsr_gemm_3("N", "N", one, exp_H_old(re)%matrix, exp_H_old(im)%matrix, &
                                            rho_old(re)%matrix, rho_old(im)%matrix, zero, tmp_re, tmp_im, filter_eps=rtp%filter_eps)
               CALL cp_complex_dbcsr_gemm_3("N", "C", one, tmp_re, tmp_im, exp_H_old(re)%matrix, exp_H_old(im)%matrix, &
                                            zero, rho_next(re)%matrix, rho_next(im)%matrix, filter_eps=rtp%filter_eps)
            ELSE
               CALL dbcsr_copy(rho_next(re)%matrix, rho_old(re)%matrix)
               CALL dbcsr_copy(rho_next(im)%matrix, rho_old(im)%matrix)
            END IF
         END IF
         CALL cp_complex_dbcsr_gemm_3("N", "N", one, exp_H_new(re)%matrix, exp_H_new(im)%matrix, &
                                      rho_next(re)%matrix, rho_next(im)%matrix, zero, tmp_re, tmp_im, filter_eps=rtp%filter_eps)
         CALL cp_complex_dbcsr_gemm_3("N", "C", one, tmp_re, tmp_im, exp_H_new(re)%matrix, exp_H_new(im)%matrix, &
                                      zero, rho_new(re)%matrix, rho_new(im)%matrix, filter_eps=rtp%filter_eps)
      END DO

      CALL dbcsr_deallocate_matrix(tmp_re)
      CALL dbcsr_deallocate_matrix(tmp_im)

      CALL timestop(handle)

   END SUBROUTINE propagate_exp_density

! **************************************************************************************************
!> \brief computes U_prop*MOs using arnoldi subspace algorithm
!> \param rtp ...
!> \param rtp_control ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE propagate_arnoldi(rtp, rtp_control)
      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER                        :: routineN = 'propagate_arnoldi'

      INTEGER                                            :: handle, i, im, ispin, nspin, re
      REAL(dp)                                           :: eps_arnoldi, t
      TYPE(cp_fm_type), ALLOCATABLE, DIMENSION(:)        :: propagator_matrix_fm
      TYPE(cp_fm_type), DIMENSION(:), POINTER            :: mos_new, mos_next, mos_old
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: propagator_matrix

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, dt=t, mos_new=mos_new, mos_old=mos_old, &
                   mos_next=mos_next, propagator_matrix=propagator_matrix)

      nspin = SIZE(mos_new)/2
      eps_arnoldi = rtp_control%eps_exp
      ! except for the first step the further propagated mos_next
      ! must be copied on mos_old so that we have the half propagated mos
      ! ready on mos_old and only need to perform the second half propagatioon
      IF (rtp_control%propagator == do_etrs .AND. rtp%iter == 1) THEN
         DO i = 1, SIZE(mos_new)
            CALL cp_fm_to_fm(mos_next(i), mos_old(i))
         END DO
      END IF

      ALLOCATE (propagator_matrix_fm(SIZE(propagator_matrix)))
      DO i = 1, SIZE(propagator_matrix)
         CALL cp_fm_create(propagator_matrix_fm(i), &
                           matrix_struct=rtp%ao_ao_fmstruct, &
                           name="prop_fm")
         CALL copy_dbcsr_to_fm(propagator_matrix(i)%matrix, propagator_matrix_fm(i))
      END DO

      DO ispin = 1, nspin
         re = ispin*2 - 1
         im = ispin*2
         IF (rtp_control%fixed_ions .AND. .NOT. rtp%do_hfx) THEN
            CALL arnoldi(mos_old(re:im), mos_new(re:im), &
                         eps_arnoldi, Him=propagator_matrix_fm(im), &
                         mos_next=mos_next(re:im), narn_old=rtp%narn_old)
         ELSE
            CALL arnoldi(mos_old(re:im), mos_new(re:im), &
                         eps_arnoldi, Hre=propagator_matrix_fm(re), &
                         Him=propagator_matrix_fm(im), mos_next=mos_next(re:im), &
                         narn_old=rtp%narn_old)
         END IF
      END DO

!    DO i=1,SIZE(propagator_matrix)
!         CALL copy_fm_to_dbcsr(propagator_matrix_fm(i), propagator_matrix(i)%matrix)
!    END DO
      CALL cp_fm_vect_dealloc(propagator_matrix_fm)

      CALL timestop(handle)

   END SUBROUTINE propagate_arnoldi

! **************************************************************************************************
!> \brief  Propagation using the Baker-Campbell-Hausdorff expansion,
!>         currently only works for rtp
!> \param rtp ...
!> \param rtp_control ...
!> \author Samuel Andermatt (02.2014)
! **************************************************************************************************

   SUBROUTINE propagate_bch(rtp, rtp_control)

      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CHARACTER(len=*), PARAMETER                        :: routineN = 'propagate_bch'

      INTEGER                                            :: handle, im, ispin, re
      REAL(dp)                                           :: dt
      REAL(KIND=dp)                                      :: prefac
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: exp_H_old, propagator_matrix, rho_new, &
                                                            rho_next, rho_old

      CALL timeset(routineN, handle)

      CALL get_rtp(rtp=rtp, propagator_matrix=propagator_matrix, rho_old=rho_old, rho_new=rho_new, &
                   rho_next=rho_next)

      DO ispin = 1, SIZE(propagator_matrix)/2
         re = 2*ispin - 1
         im = 2*ispin

         IF (rtp%iter == 1) THEN
            ! For EM I have to copy rho_old onto rho_next and for ETRS,
            ! this is the first term of the series of commutators that result in rho_next
            CALL dbcsr_copy(rho_next(re)%matrix, rho_old(re)%matrix)
            CALL dbcsr_copy(rho_next(im)%matrix, rho_old(im)%matrix)
            IF (rtp_control%propagator == do_etrs) THEN
               !since we never calculated the matrix exponential the old matrix exponential stores the unscalled propagator
               CALL get_rtp(rtp=rtp, exp_H_old=exp_H_old, dt=dt)
               prefac = -0.5_dp*dt
               CALL dbcsr_scale(exp_H_old(im)%matrix, prefac)
               IF (.NOT. rtp%do_hfx .AND. rtp_control%fixed_ions) THEN
                  CALL bch_expansion_imaginary_propagator( &
                     exp_H_old(im)%matrix, rho_next(re)%matrix, rho_next(im)%matrix, &
                     rtp%filter_eps, rtp%filter_eps_small, rtp_control%eps_exp)
               ELSE
                  CALL dbcsr_scale(exp_H_old(re)%matrix, prefac)
                  CALL bch_expansion_complex_propagator( &
                     exp_H_old(re)%matrix, exp_H_old(im)%matrix, rho_next(re)%matrix, rho_next(im)%matrix, &
                     rtp%filter_eps, rtp%filter_eps_small, rtp_control%eps_exp)
               END IF
            END IF
         END IF
         CALL dbcsr_copy(rho_new(re)%matrix, rho_next(re)%matrix)
         CALL dbcsr_copy(rho_new(im)%matrix, rho_next(im)%matrix)
         IF (.NOT. rtp%do_hfx .AND. rtp_control%fixed_ions) THEN
            CALL bch_expansion_imaginary_propagator( &
               propagator_matrix(im)%matrix, rho_new(re)%matrix, rho_new(im)%matrix, &
               rtp%filter_eps, rtp%filter_eps_small, rtp_control%eps_exp)
         ELSE
            CALL bch_expansion_complex_propagator( &
               propagator_matrix(re)%matrix, propagator_matrix(im)%matrix, rho_new(re)%matrix, rho_new(im)%matrix, &
               rtp%filter_eps, rtp%filter_eps_small, rtp_control%eps_exp)
         END IF

      END DO

      CALL timestop(handle)

   END SUBROUTINE propagate_bch

! **************************************************************************************************
!> \brief decides which type of exponential has to be computed
!> \param propagator ...
!> \param propagator_matrix ...
!> \param rtp_control ...
!> \param rtp ...
!> \author Florian Schiffmann (02.09)
! **************************************************************************************************

   SUBROUTINE compute_exponential(propagator, propagator_matrix, rtp_control, rtp)
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: propagator, propagator_matrix
      TYPE(rtp_control_type), POINTER                    :: rtp_control
      TYPE(rt_prop_type), POINTER                        :: rtp

      INTEGER                                            :: i, im, ispin, re
      TYPE(cp_fm_type), ALLOCATABLE, DIMENSION(:)        :: propagator_fm, propagator_matrix_fm

      ALLOCATE (propagator_fm(SIZE(propagator)))
      ALLOCATE (propagator_matrix_fm(SIZE(propagator_matrix)))
      DO i = 1, SIZE(propagator)
         CALL cp_fm_create(propagator_fm(i), &
                           matrix_struct=rtp%ao_ao_fmstruct, &
                           name="prop_fm")
         CALL copy_dbcsr_to_fm(propagator(i)%matrix, propagator_fm(i))
         CALL cp_fm_create(propagator_matrix_fm(i), &
                           matrix_struct=rtp%ao_ao_fmstruct, &
                           name="prop_mat_fm")
         CALL copy_dbcsr_to_fm(propagator_matrix(i)%matrix, propagator_matrix_fm(i))
      END DO

      DO ispin = 1, SIZE(propagator)/2
         re = 2*ispin - 1
         im = 2*ispin

         SELECT CASE (rtp_control%mat_exp)

         CASE (do_taylor)
            IF (rtp_control%fixed_ions .AND. .NOT. rtp%do_hfx) THEN
               CALL taylor_only_imaginary(propagator_fm(re:im), propagator_matrix_fm(im), &
                                          rtp%orders(1, ispin), rtp%orders(2, ispin))
            ELSE
               CALL taylor_full_complex(propagator_fm(re:im), propagator_matrix_fm(re), propagator_matrix_fm(im), &
                                        rtp%orders(1, ispin), rtp%orders(2, ispin))
            END IF
         CASE (do_pade)
            IF (rtp_control%fixed_ions .AND. .NOT. rtp%do_hfx) THEN
               CALL exp_pade_only_imaginary(propagator_fm(re:im), propagator_matrix_fm(im), &
                                            rtp%orders(1, ispin), rtp%orders(2, ispin))
            ELSE
               CALL exp_pade_full_complex(propagator_fm(re:im), propagator_matrix_fm(re), propagator_matrix_fm(im), &
                                          rtp%orders(1, ispin), rtp%orders(2, ispin))
            END IF
         END SELECT
      END DO

      DO i = 1, SIZE(propagator)
         CALL copy_fm_to_dbcsr(propagator_fm(i), propagator(i)%matrix)
         CALL copy_fm_to_dbcsr(propagator_matrix_fm(i), propagator_matrix(i)%matrix)
      END DO
      CALL cp_fm_vect_dealloc(propagator_fm)
      CALL cp_fm_vect_dealloc(propagator_matrix_fm)

   END SUBROUTINE compute_exponential

! **************************************************************************************************
!> \brief Sparse versions of the matrix exponentials
!> \param propagator ...
!> \param propagator_matrix ...
!> \param rtp_control ...
!> \param rtp ...
!> \author Samuel Andermatt (02.14)
! **************************************************************************************************

   SUBROUTINE compute_exponential_sparse(propagator, propagator_matrix, rtp_control, rtp)
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: propagator, propagator_matrix
      TYPE(rtp_control_type), POINTER                    :: rtp_control
      TYPE(rt_prop_type), POINTER                        :: rtp

      CHARACTER(len=*), PARAMETER :: routineN = 'compute_exponential_sparse'

      INTEGER                                            :: handle, im, ispin, re

      CALL timeset(routineN, handle)

      DO ispin = 1, SIZE(propagator)/2
         re = 2*ispin - 1
         im = 2*ispin
         IF (rtp_control%fixed_ions .AND. .NOT. rtp%do_hfx) THEN
            CALL taylor_only_imaginary_dbcsr(propagator(re:im), propagator_matrix(im)%matrix, &
                                             rtp%orders(1, ispin), rtp%orders(2, ispin), rtp%filter_eps)
         ELSE
            CALL taylor_full_complex_dbcsr(propagator(re:im), propagator_matrix(re)%matrix, propagator_matrix(im)%matrix, &
                                           rtp%orders(1, ispin), rtp%orders(2, ispin), rtp%filter_eps)
         END IF
      END DO

      CALL timestop(handle)

   END SUBROUTINE compute_exponential_sparse

END MODULE rt_make_propagators
