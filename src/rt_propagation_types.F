!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Types and set_get for real time propagation
!>        depending on runtype and diagonalization method different
!>        matrices are allocated
!>        exp_H_old, exp_H_new, mos_new, mos_old contain always
!>        real and imaginary parts of the matrices
!>        odd index = real part (alpha, beta spin)
!>        even index= imaginary part (alpha, beta spin)
!> \par History
!>      02.2014 switched to dbcsr matrices [Samuel Andermatt]
!> \author Florian Schiffmann 02.09
! **************************************************************************************************

MODULE rt_propagation_types

   USE bibliography,                    ONLY: Kunert2003,&
                                              cite_reference
   USE cp_control_types,                ONLY: dft_control_type,&
                                              rtp_control_type
   USE cp_dbcsr_operations,             ONLY: dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_fm_pool_types,                ONLY: cp_fm_pool_p_type,&
                                              fm_pool_get_el_struct
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_get,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE cp_fm_vect,                      ONLY: cp_fm_vect_dealloc
   USE cp_log_handling,                 ONLY: cp_to_string
   USE dbcsr_api,                       ONLY: dbcsr_create,&
                                              dbcsr_deallocate_matrix,&
                                              dbcsr_init_p,&
                                              dbcsr_p_type,&
                                              dbcsr_type
   USE kinds,                           ONLY: dp
   USE qs_matrix_pools,                 ONLY: mpools_get,&
                                              qs_matrix_pools_type
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'rt_propagation_types'

   TYPE rtp_rho_type
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:) :: new
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:) :: old
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:) :: next
   END TYPE rtp_rho_type

   TYPE rtp_history_type
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:, :)               :: rho_history
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)                 :: s_history
      TYPE(cp_fm_type), POINTER, DIMENSION(:, :)                :: mo_history
   END TYPE rtp_history_type

   TYPE rtp_mos_type
      TYPE(cp_fm_type), POINTER, DIMENSION(:)     :: new
      TYPE(cp_fm_type), POINTER, DIMENSION(:)     :: old
      TYPE(cp_fm_type), POINTER, DIMENSION(:)     :: next
      TYPE(cp_fm_type), POINTER, DIMENSION(:)     :: admm
   END TYPE rtp_mos_type

   TYPE rt_prop_type
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: exp_H_old
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: exp_H_new
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: H_last_iter
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: propagator_matrix
      TYPE(dbcsr_type), POINTER                 :: S_inv
      TYPE(dbcsr_type), POINTER                 :: S_half
      TYPE(dbcsr_type), POINTER                 :: S_minus_half
      TYPE(dbcsr_type), POINTER                 :: B_mat
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: C_mat
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: S_der
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:)  :: SinvH
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:) :: SinvB
      TYPE(rtp_rho_type), POINTER                  :: rho
      TYPE(rtp_mos_type), POINTER                  :: mos
      REAL(KIND=dp)                               :: energy_old
      REAL(KIND=dp)                               :: energy_new
      REAL(KIND=dp)                               :: dt
      REAL(KIND=dp)                               :: delta_iter
      REAL(KIND=dp)                               :: delta_iter_old
      REAL(KIND=dp)                               :: filter_eps
      REAL(KIND=dp)                               :: filter_eps_small
      REAL(KIND=dp)                               :: mixing_factor
      LOGICAL                                     :: mixing
      LOGICAL                                     :: do_hfx
      LOGICAL                                     :: track_imag_density
      INTEGER, DIMENSION(:, :), ALLOCATABLE          :: orders
      INTEGER                                     :: nsteps, istep, i_start, max_steps
      INTEGER                                     :: iter
      INTEGER                                     :: narn_old
      LOGICAL                                     :: converged
      LOGICAL                                     :: matrix_update
      LOGICAL                                     :: write_restart
      TYPE(rtp_history_type), POINTER              :: history
      TYPE(cp_fm_struct_type), POINTER            :: ao_ao_fmstruct
      INTEGER                                     :: lanzcos_max_iter
      REAL(KIND=dp)                               :: lanzcos_threshold
      INTEGER                                     :: newton_schulz_order
      LOGICAL                                     :: linear_scaling
   END TYPE rt_prop_type

! *** Public data types ***

   PUBLIC :: rt_prop_type

! *** Public subroutines ***

   PUBLIC :: rt_prop_create, &
             get_rtp, &
             rt_prop_release, &
             rtp_history_create
CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
!> \param mos ...
!> \param mpools ...
!> \param dft_control ...
!> \param template ...
!> \param linear_scaling ...
!> \param mos_aux ...
! **************************************************************************************************
   SUBROUTINE rt_prop_create(rtp, mos, mpools, dft_control, template, linear_scaling, mos_aux)

      TYPE(rt_prop_type), POINTER                        :: rtp
      TYPE(mo_set_type), DIMENSION(:), INTENT(IN)        :: mos
      TYPE(qs_matrix_pools_type), POINTER                :: mpools
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(dbcsr_type), POINTER                          :: template
      LOGICAL, INTENT(IN)                                :: linear_scaling
      TYPE(mo_set_type), DIMENSION(:), OPTIONAL, POINTER :: mos_aux

      INTEGER                                            :: i, j, nao, nrow_block, nspin
      TYPE(cp_fm_pool_p_type), DIMENSION(:), POINTER     :: ao_mo_fm_pools
      TYPE(cp_fm_struct_type), POINTER                   :: ao_mo_fmstruct
      TYPE(rtp_control_type), POINTER                    :: rtp_control

      CALL cite_reference(Kunert2003)

      NULLIFY (rtp_control)

      rtp_control => dft_control%rtp_control

      nspin = dft_control%nspins

      NULLIFY (rtp%mos, rtp%rho)
      rtp%linear_scaling = linear_scaling

      IF (rtp%linear_scaling) THEN
         ALLOCATE (rtp%rho)
         NULLIFY (rtp%rho%old)
         CALL dbcsr_allocate_matrix_set(rtp%rho%old, 2*nspin)
         NULLIFY (rtp%rho%next)
         CALL dbcsr_allocate_matrix_set(rtp%rho%next, 2*nspin)
         NULLIFY (rtp%rho%new)
         CALL dbcsr_allocate_matrix_set(rtp%rho%new, 2*nspin)
         DO i = 1, 2*nspin
            CALL dbcsr_init_p(rtp%rho%old(i)%matrix)
            CALL dbcsr_create(rtp%rho%old(i)%matrix, template=template, matrix_type="N")
            CALL dbcsr_init_p(rtp%rho%next(i)%matrix)
            CALL dbcsr_create(rtp%rho%next(i)%matrix, template=template, matrix_type="N")
            CALL dbcsr_init_p(rtp%rho%new(i)%matrix)
            CALL dbcsr_create(rtp%rho%new(i)%matrix, template=template, matrix_type="N")
         END DO
      ELSE
         CALL mpools_get(mpools, ao_mo_fm_pools=ao_mo_fm_pools)

         ao_mo_fmstruct => fm_pool_get_el_struct(ao_mo_fm_pools(1)%pool)
         CALL cp_fm_struct_get(ao_mo_fmstruct, nrow_block=nrow_block)
         CALL get_mo_set(mos(1), nao=nao)

         CALL cp_fm_struct_create(fmstruct=rtp%ao_ao_fmstruct, &
                                  nrow_block=nrow_block, ncol_block=nrow_block, &
                                  nrow_global=nao, ncol_global=nao, &
                                  template_fmstruct=ao_mo_fmstruct)
         ALLOCATE (rtp%mos)
         ALLOCATE (rtp%mos%old(2*nspin))
         ALLOCATE (rtp%mos%new(2*nspin))
         ALLOCATE (rtp%mos%next(2*nspin))
         NULLIFY (rtp%mos%admm)
         IF (dft_control%do_admm) THEN
            IF (PRESENT(mos_aux)) THEN
               CPASSERT(ASSOCIATED(mos_aux))
            ELSE
               CPABORT("The optional argument mos_aux is missing which is required with ADMM")
            END IF
            ALLOCATE (rtp%mos%admm(2*nspin))
         END IF
         DO i = 1, nspin
            DO j = 1, 2
               CALL cp_fm_create(rtp%mos%old(2*(i - 1) + j), &
                                 matrix_struct=mos(i)%mo_coeff%matrix_struct, &
                                 name="mos_old"//TRIM(ADJUSTL(cp_to_string(2*(i - 1) + j))))
               CALL cp_fm_create(rtp%mos%new(2*(i - 1) + j), &
                                 matrix_struct=mos(i)%mo_coeff%matrix_struct, &
                                 name="mos_new"//TRIM(ADJUSTL(cp_to_string(2*(i - 1) + j))))
               CALL cp_fm_create(rtp%mos%next(2*(i - 1) + j), &
                                 matrix_struct=mos(i)%mo_coeff%matrix_struct, &
                                 name="mos_next"//TRIM(ADJUSTL(cp_to_string(2*(i - 1) + j))))
               IF (dft_control%do_admm) THEN
                  CALL cp_fm_create(rtp%mos%admm(2*(i - 1) + j), &
                                    matrix_struct=mos_aux(i)%mo_coeff%matrix_struct, &
                                    name="mos_admm"//TRIM(ADJUSTL(cp_to_string(2*(i - 1) + j))))
               END IF
            END DO
         END DO
      END IF

      NULLIFY (rtp%exp_H_old)
      NULLIFY (rtp%exp_H_new)
      NULLIFY (rtp%H_last_iter)
      NULLIFY (rtp%propagator_matrix)
      CALL dbcsr_allocate_matrix_set(rtp%exp_H_old, 2*nspin)
      CALL dbcsr_allocate_matrix_set(rtp%exp_H_new, 2*nspin)
      CALL dbcsr_allocate_matrix_set(rtp%H_last_iter, 2*nspin)
      CALL dbcsr_allocate_matrix_set(rtp%propagator_matrix, 2*nspin)
      DO i = 1, 2*nspin
         CALL dbcsr_init_p(rtp%exp_H_old(i)%matrix)
         CALL dbcsr_create(rtp%exp_H_old(i)%matrix, template=template, matrix_type="N")
         CALL dbcsr_init_p(rtp%exp_H_new(i)%matrix)
         CALL dbcsr_create(rtp%exp_H_new(i)%matrix, template=template, matrix_type="N")
         CALL dbcsr_init_p(rtp%H_last_iter(i)%matrix)
         CALL dbcsr_create(rtp%H_last_iter(i)%matrix, template=template, matrix_type="N")
         CALL dbcsr_init_p(rtp%propagator_matrix(i)%matrix)
         CALL dbcsr_create(rtp%propagator_matrix(i)%matrix, template=template, matrix_type="N")
      END DO
      NULLIFY (rtp%S_inv)
      ALLOCATE (rtp%S_inv)
      CALL dbcsr_create(rtp%S_inv, template=template, matrix_type="S")
      NULLIFY (rtp%S_half)
      ALLOCATE (rtp%S_half)
      CALL dbcsr_create(rtp%S_half, template=template, matrix_type="S")
      NULLIFY (rtp%S_minus_half)
      ALLOCATE (rtp%S_minus_half)
      CALL dbcsr_create(rtp%S_minus_half, template=template, matrix_type="S")
      NULLIFY (rtp%B_mat)
      NULLIFY (rtp%C_mat)
      NULLIFY (rtp%S_der)
      NULLIFY (rtp%SinvH)
      NULLIFY (rtp%SinvB)
      IF (.NOT. rtp_control%fixed_ions) THEN
         ALLOCATE (rtp%B_mat)
         CALL dbcsr_create(rtp%B_mat, template=template, matrix_type="N")
         CALL dbcsr_allocate_matrix_set(rtp%C_mat, 3)
         CALL dbcsr_allocate_matrix_set(rtp%S_der, 9)
         CALL dbcsr_allocate_matrix_set(rtp%SinvH, nspin)
         CALL dbcsr_allocate_matrix_set(rtp%SinvB, nspin)
         DO i = 1, nspin
            CALL dbcsr_init_p(rtp%SinvH(i)%matrix)
            CALL dbcsr_create(rtp%SinvH(i)%matrix, template=template, matrix_type="N")
            CALL dbcsr_init_p(rtp%SinvB(i)%matrix)
            CALL dbcsr_create(rtp%SinvB(i)%matrix, template=template, matrix_type="N")
         END DO
         DO i = 1, 3
            CALL dbcsr_init_p(rtp%C_mat(i)%matrix)
            CALL dbcsr_create(rtp%C_mat(i)%matrix, template=template, matrix_type="N")
         END DO
         DO i = 1, 9
            CALL dbcsr_init_p(rtp%S_der(i)%matrix)
            CALL dbcsr_create(rtp%S_der(i)%matrix, template=template, matrix_type="N")
         END DO
      END IF
      ALLOCATE (rtp%orders(2, nspin))
      rtp_control%converged = .FALSE.
      rtp%matrix_update = .TRUE.
      rtp%narn_old = 0
      rtp%istep = 0
      rtp%iter = 0
      rtp%do_hfx = .FALSE.
      rtp%track_imag_density = .FALSE.

   END SUBROUTINE rt_prop_create

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
!> \param exp_H_old ...
!> \param exp_H_new ...
!> \param H_last_iter ...
!> \param rho_old ...
!> \param rho_next ...
!> \param rho_new ...
!> \param mos ...
!> \param mos_new ...
!> \param mos_old ...
!> \param mos_next ...
!> \param S_inv ...
!> \param S_half ...
!> \param S_minus_half ...
!> \param B_mat ...
!> \param C_mat ...
!> \param propagator_matrix ...
!> \param mixing ...
!> \param mixing_factor ...
!> \param S_der ...
!> \param dt ...
!> \param nsteps ...
!> \param SinvH ...
!> \param SinvB ...
!> \param admm_mos ...
! **************************************************************************************************
   SUBROUTINE get_rtp(rtp, exp_H_old, exp_H_new, H_last_iter, rho_old, rho_next, rho_new, mos, mos_new, mos_old, mos_next, &
                      S_inv, S_half, S_minus_half, B_mat, C_mat, propagator_matrix, mixing, mixing_factor, &
                      S_der, dt, nsteps, SinvH, SinvB, admm_mos)

      TYPE(rt_prop_type), INTENT(IN)                     :: rtp
      TYPE(dbcsr_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: exp_H_old, exp_H_new, H_last_iter, &
                                                            rho_old, rho_next, rho_new
      TYPE(rtp_mos_type), OPTIONAL, POINTER              :: mos
      TYPE(cp_fm_type), DIMENSION(:), OPTIONAL, POINTER  :: mos_new, mos_old, mos_next
      TYPE(dbcsr_type), OPTIONAL, POINTER                :: S_inv, S_half, S_minus_half, B_mat
      TYPE(dbcsr_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: C_mat, propagator_matrix
      LOGICAL, OPTIONAL                                  :: mixing
      REAL(dp), INTENT(out), OPTIONAL                    :: mixing_factor
      TYPE(dbcsr_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: S_der
      REAL(dp), INTENT(out), OPTIONAL                    :: dt
      INTEGER, INTENT(out), OPTIONAL                     :: nsteps
      TYPE(dbcsr_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: SinvH, SinvB
      TYPE(cp_fm_type), DIMENSION(:), OPTIONAL, POINTER  :: admm_mos

      IF (PRESENT(exp_H_old)) exp_H_old => rtp%exp_H_old
      IF (PRESENT(exp_H_new)) exp_H_new => rtp%exp_H_new
      IF (PRESENT(H_last_iter)) H_last_iter => rtp%H_last_iter
      IF (PRESENT(propagator_matrix)) propagator_matrix => rtp%propagator_matrix

      IF (PRESENT(rho_old)) rho_old => rtp%rho%old
      IF (PRESENT(rho_next)) rho_next => rtp%rho%next
      IF (PRESENT(rho_new)) rho_new => rtp%rho%new
      IF (PRESENT(mos)) mos => rtp%mos
      IF (PRESENT(mos_old)) mos_old => rtp%mos%old
      IF (PRESENT(mos_new)) mos_new => rtp%mos%new
      IF (PRESENT(mos_next)) mos_next => rtp%mos%next
      IF (PRESENT(admm_mos)) admm_mos => rtp%mos%admm

      IF (PRESENT(S_inv)) S_inv => rtp%S_inv
      IF (PRESENT(S_half)) S_half => rtp%S_half
      IF (PRESENT(S_minus_half)) S_minus_half => rtp%S_minus_half
      IF (PRESENT(B_mat)) B_mat => rtp%B_mat
      IF (PRESENT(C_mat)) C_mat => rtp%C_mat
      IF (PRESENT(SinvH)) SinvH => rtp%SinvH
      IF (PRESENT(SinvB)) SinvB => rtp%SinvB
      IF (PRESENT(S_der)) S_der => rtp%S_der

      IF (PRESENT(dt)) dt = rtp%dt
      IF (PRESENT(mixing)) mixing = rtp%mixing
      IF (PRESENT(mixing_factor)) mixing_factor = rtp%mixing_factor
      IF (PRESENT(nsteps)) nsteps = rtp%nsteps

   END SUBROUTINE get_rtp

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
! **************************************************************************************************
   SUBROUTINE rt_prop_release(rtp)
      TYPE(rt_prop_type), INTENT(inout)                  :: rtp

      CALL dbcsr_deallocate_matrix_set(rtp%exp_H_old)
      CALL dbcsr_deallocate_matrix_set(rtp%exp_H_new)
      CALL dbcsr_deallocate_matrix_set(rtp%H_last_iter)
      CALL dbcsr_deallocate_matrix_set(rtp%propagator_matrix)
      IF (ASSOCIATED(rtp%rho)) THEN
         IF (ASSOCIATED(rtp%rho%old)) &
            CALL dbcsr_deallocate_matrix_set(rtp%rho%old)
         IF (ASSOCIATED(rtp%rho%next)) &
            CALL dbcsr_deallocate_matrix_set(rtp%rho%next)
         IF (ASSOCIATED(rtp%rho%new)) &
            CALL dbcsr_deallocate_matrix_set(rtp%rho%new)
         DEALLOCATE (rtp%rho)
      END IF
      IF (ASSOCIATED(rtp%mos)) THEN
         IF (ASSOCIATED(rtp%mos%old)) &
            CALL cp_fm_vect_dealloc(rtp%mos%old)
         IF (ASSOCIATED(rtp%mos%new)) &
            CALL cp_fm_vect_dealloc(rtp%mos%new)
         IF (ASSOCIATED(rtp%mos%next)) &
            CALL cp_fm_vect_dealloc(rtp%mos%next)
         IF (ASSOCIATED(rtp%mos%admm)) &
            CALL cp_fm_vect_dealloc(rtp%mos%admm)
         DEALLOCATE (rtp%mos)
      END IF
      CALL dbcsr_deallocate_matrix(rtp%S_inv)
      CALL dbcsr_deallocate_matrix(rtp%S_half)
      CALL dbcsr_deallocate_matrix(rtp%S_minus_half)
      IF (ASSOCIATED(rtp%B_mat)) &
         CALL dbcsr_deallocate_matrix(rtp%B_mat)
      IF (ASSOCIATED(rtp%C_mat)) &
         CALL dbcsr_deallocate_matrix_set(rtp%C_mat)
      IF (ASSOCIATED(rtp%S_der)) &
         CALL dbcsr_deallocate_matrix_set(rtp%S_der)
      IF (ASSOCIATED(rtp%SinvH)) &
         CALL dbcsr_deallocate_matrix_set(rtp%SinvH)
      IF (ASSOCIATED(rtp%SinvB)) &
         CALL dbcsr_deallocate_matrix_set(rtp%SinvB)
      IF (ASSOCIATED(rtp%history)) &
         CALL rtp_history_release(rtp)
      DEALLOCATE (rtp%orders)
      IF (.NOT. rtp%linear_scaling) CALL cp_fm_struct_release(rtp%ao_ao_fmstruct)
   END SUBROUTINE rt_prop_release

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
!> \param aspc_order ...
! **************************************************************************************************
   SUBROUTINE rtp_history_create(rtp, aspc_order)
      TYPE(rt_prop_type), INTENT(inout)                  :: rtp
      INTEGER, INTENT(in)                                :: aspc_order

      INTEGER                                            :: i, j, nmat
      TYPE(rtp_history_type), POINTER                    :: history

      NULLIFY (history)
      ALLOCATE (rtp%history)
      history => rtp%history

      NULLIFY (history%rho_history, history%mo_history, history%s_history)
      IF (aspc_order .GT. 0) THEN
         IF (rtp%linear_scaling) THEN
            nmat = SIZE(rtp%rho%new)
            CALL dbcsr_allocate_matrix_set(history%rho_history, nmat, aspc_order)
            DO i = 1, nmat
               DO j = 1, aspc_order
                  CALL dbcsr_init_p(history%rho_history(i, j)%matrix)
                  CALL dbcsr_create(history%rho_history(i, j)%matrix, &
                                    name="rho_hist"//TRIM(ADJUSTL(cp_to_string(i))), &
                                    template=rtp%rho%new(1)%matrix)
               END DO
            END DO
         ELSE
            nmat = SIZE(rtp%mos%old)
            ALLOCATE (history%mo_history(nmat, aspc_order))
            DO i = 1, nmat
               DO j = 1, aspc_order
                  CALL cp_fm_create(history%mo_history(i, j), &
                                    matrix_struct=rtp%mos%new(i)%matrix_struct, &
                                    name="mo_hist"//TRIM(ADJUSTL(cp_to_string(i))))
               END DO
            END DO
            ALLOCATE (history%s_history(aspc_order))
            DO i = 1, aspc_order
               NULLIFY (history%s_history(i)%matrix)
            END DO
         END IF
      END IF

   END SUBROUTINE rtp_history_create

! **************************************************************************************************
!> \brief ...
!> \param rtp ...
! **************************************************************************************************
   SUBROUTINE rtp_history_release(rtp)
      TYPE(rt_prop_type), INTENT(inout)                  :: rtp

      INTEGER                                            :: i, j

      IF (ASSOCIATED(rtp%history%rho_history)) THEN
         CALL dbcsr_deallocate_matrix_set(rtp%history%rho_history)
      END IF

      IF (ASSOCIATED(rtp%history%mo_history)) THEN
         DO i = 1, SIZE(rtp%history%mo_history, 1)
            DO j = 1, SIZE(rtp%history%mo_history, 2)
               CALL cp_fm_release(rtp%history%mo_history(i, j))
            END DO
         END DO
         DEALLOCATE (rtp%history%mo_history)
      END IF
      IF (ASSOCIATED(rtp%history%s_history)) THEN
         DO i = 1, SIZE(rtp%history%s_history)
            IF (ASSOCIATED(rtp%history%s_history(i)%matrix)) &
               CALL dbcsr_deallocate_matrix(rtp%history%s_history(i)%matrix)
         END DO
         DEALLOCATE (rtp%history%s_history)
      END IF
      DEALLOCATE (rtp%history)

   END SUBROUTINE rtp_history_release

END MODULE rt_propagation_types
