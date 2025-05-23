!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines for calculating a complex matrix exponential with dbcsr matrices.
!>        Based on the code in matrix_exp.F from Florian Schiffmann
!> \author Samuel Andermatt (02.14)
! **************************************************************************************************

MODULE ls_matrix_exp

   USE cp_log_handling,                 ONLY: cp_logger_get_default_io_unit
   USE dbcsr_api,                       ONLY: &
        dbcsr_add, dbcsr_add_on_diag, dbcsr_copy, dbcsr_create, dbcsr_deallocate_matrix, &
        dbcsr_filter, dbcsr_frobenius_norm, dbcsr_multiply, dbcsr_p_type, dbcsr_scale, dbcsr_set, &
        dbcsr_transposed, dbcsr_type, dbcsr_type_complex_8
   USE kinds,                           ONLY: dp
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'ls_matrix_exp'

   PUBLIC :: taylor_only_imaginary_dbcsr, &
             taylor_full_complex_dbcsr, &
             cp_complex_dbcsr_gemm_3, &
             bch_expansion_imaginary_propagator, &
             bch_expansion_complex_propagator

CONTAINS

! **************************************************************************************************
!> \brief Convenience function. Computes the matrix multiplications needed
!>        for the multiplication of complex sparse matrices.
!>        C = beta * C + alpha * ( A  ** transa ) * ( B ** transb )
!> \param transa : 'N' -> normal   'T' -> transpose
!>      alpha,beta :: can be 0.0_dp and 1.0_dp
!> \param transb ...
!> \param alpha ...
!> \param A_re m x k matrix ( ! for transa = 'N'), real part
!> \param A_im m x k matrix ( ! for transa = 'N'), imaginary part
!> \param B_re k x n matrix ( ! for transb = 'N'), real part
!> \param B_im k x n matrix ( ! for transb = 'N'), imaginary part
!> \param beta ...
!> \param C_re m x n matrix, real part
!> \param C_im m x n matrix, imaginary part
!> \param filter_eps ...
!> \author Samuel Andermatt
!> \note
!>      C should have no overlap with A, B
!>      This subroutine uses three real matrix multiplications instead of two complex
!>      This reduces the amount of flops and memory bandwidth by 25%, but for memory bandwidth
!>      true complex algebra is still superior (one third less bandwidth needed)
!>      limited cases matrix multiplications
! **************************************************************************************************

   SUBROUTINE cp_complex_dbcsr_gemm_3(transa, transb, alpha, A_re, A_im, &
                                      B_re, B_im, beta, C_re, C_im, filter_eps)
      CHARACTER(LEN=1), INTENT(IN)                       :: transa, transb
      REAL(KIND=dp), INTENT(IN)                          :: alpha
      TYPE(dbcsr_type), INTENT(IN)                       :: A_re, A_im, B_re, B_im
      REAL(KIND=dp), INTENT(IN)                          :: beta
      TYPE(dbcsr_type), INTENT(INOUT)                    :: C_re, C_im
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: filter_eps

      CHARACTER(len=*), PARAMETER :: routineN = 'cp_complex_dbcsr_gemm_3'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      CHARACTER(LEN=1)                                   :: transa2, transb2
      INTEGER                                            :: handle
      REAL(KIND=dp)                                      :: alpha2, alpha3, alpha4
      TYPE(dbcsr_type), POINTER                          :: a_plus_b, ac, bd, c_plus_d

      CALL timeset(routineN, handle)
      !A complex matrix matrix multiplication can be done with only three multiplications
      !(a+ib)*(c+id)=ac-bd+i((a+b)*(c+d) - ac - bd)
      !A_re=a, A_im=b, B_re=c, B_im=d

      alpha2 = -alpha
      alpha3 = alpha
      alpha4 = alpha

      IF (transa == "C") THEN
         alpha2 = -alpha2
         alpha3 = -alpha3
         transa2 = "T"
      ELSE
         transa2 = transa
      END IF
      IF (transb == "C") THEN
         alpha2 = -alpha2
         alpha4 = -alpha4
         transb2 = "T"
      ELSE
         transb2 = transb
      END IF

      !create the work matrices
      NULLIFY (ac)
      ALLOCATE (ac)
      CALL dbcsr_create(ac, template=A_re, matrix_type="N")
      NULLIFY (bd)
      ALLOCATE (bd)
      CALL dbcsr_create(bd, template=A_re, matrix_type="N")
      NULLIFY (a_plus_b)
      ALLOCATE (a_plus_b)
      CALL dbcsr_create(a_plus_b, template=A_re, matrix_type="N")
      NULLIFY (c_plus_d)
      ALLOCATE (c_plus_d)
      CALL dbcsr_create(c_plus_d, template=A_re, matrix_type="N")

      !Do the neccesarry multiplications
      CALL dbcsr_multiply(transa2, transb2, alpha, A_re, B_re, zero, ac, filter_eps=filter_eps)
      CALL dbcsr_multiply(transa2, transb2, alpha2, A_im, B_im, zero, bd, filter_eps=filter_eps)

      CALL dbcsr_add(a_plus_b, A_re, zero, alpha)
      CALL dbcsr_add(a_plus_b, A_im, one, alpha3)
      CALL dbcsr_add(c_plus_d, B_re, zero, alpha)
      CALL dbcsr_add(c_plus_d, B_im, one, alpha4)

      !this can already be written into C_im
      !now both matrixes have been scaled which means we currently multiplied by alpha squared
      CALL dbcsr_multiply(transa2, transb2, one/alpha, a_plus_b, c_plus_d, beta, C_im, filter_eps=filter_eps)

      !now add up all the terms into the result
      CALL dbcsr_add(C_re, ac, beta, one)
      !the minus sign was already taken care of at the definition of alpha2
      CALL dbcsr_add(C_re, bd, one, one)
      CALL dbcsr_filter(C_re, filter_eps)

      CALL dbcsr_add(C_im, ac, one, -one)
      !the minus sign was already taken care of at the definition of alpha2
      CALL dbcsr_add(C_im, bd, one, one)
      CALL dbcsr_filter(C_im, filter_eps)

      !Deallocate the work matrices
      CALL dbcsr_deallocate_matrix(ac)
      CALL dbcsr_deallocate_matrix(bd)
      CALL dbcsr_deallocate_matrix(a_plus_b)
      CALL dbcsr_deallocate_matrix(c_plus_d)

      CALL timestop(handle)

   END SUBROUTINE

! **************************************************************************************************
!> \brief specialized subroutine for purely imaginary matrix exponentials
!> \param exp_H ...
!> \param im_matrix ...
!> \param nsquare ...
!> \param ntaylor ...
!> \param filter_eps ...
!> \author Samuel Andermatt (02.2014)
! **************************************************************************************************

   SUBROUTINE taylor_only_imaginary_dbcsr(exp_H, im_matrix, nsquare, ntaylor, filter_eps)

      TYPE(dbcsr_p_type), DIMENSION(2)                   :: exp_H
      TYPE(dbcsr_type), POINTER                          :: im_matrix
      INTEGER, INTENT(in)                                :: nsquare, ntaylor
      REAL(KIND=dp), INTENT(in)                          :: filter_eps

      CHARACTER(len=*), PARAMETER :: routineN = 'taylor_only_imaginary_dbcsr'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, nloop
      REAL(KIND=dp)                                      :: square_fac, Tfac, tmp
      TYPE(dbcsr_type), POINTER                          :: T1, T2, Tres_im, Tres_re

      CALL timeset(routineN, handle)

      !The divider that comes from the scaling and squaring procedure
      square_fac = 1.0_dp/(2.0_dp**REAL(nsquare, dp))

      !Allocate work matrices
      NULLIFY (T1)
      ALLOCATE (T1)
      CALL dbcsr_create(T1, template=im_matrix, matrix_type="N")
      NULLIFY (T2)
      ALLOCATE (T2)
      CALL dbcsr_create(T2, template=im_matrix, matrix_type="N")
      NULLIFY (Tres_re)
      ALLOCATE (Tres_re)
      CALL dbcsr_create(Tres_re, template=im_matrix, matrix_type="N")
      NULLIFY (Tres_im)
      ALLOCATE (Tres_im)
      CALL dbcsr_create(Tres_im, template=im_matrix, matrix_type="N")

      !Create the unit matrices
      CALL dbcsr_set(T1, zero)
      CALL dbcsr_add_on_diag(T1, one)
      CALL dbcsr_set(Tres_re, zero)
      CALL dbcsr_add_on_diag(Tres_re, one)
      CALL dbcsr_set(Tres_im, zero)

      nloop = CEILING(REAL(ntaylor, dp)/2.0_dp)
      !the inverse of the prefactor in the taylor series
      tmp = 1.0_dp
      DO i = 1, nloop
         CALL dbcsr_scale(T1, 1.0_dp/(REAL(i, dp)*2.0_dp - 1.0_dp))
         CALL dbcsr_filter(T1, filter_eps)
         CALL dbcsr_multiply("N", "N", square_fac, im_matrix, T1, zero, &
                             T2, filter_eps=filter_eps)
         Tfac = one
         IF (MOD(i, 2) == 0) Tfac = -Tfac
         CALL dbcsr_add(Tres_im, T2, one, Tfac)
         CALL dbcsr_scale(T2, 1.0_dp/(REAL(i, dp)*2.0_dp))
         CALL dbcsr_filter(T2, filter_eps)
         CALL dbcsr_multiply("N", "N", square_fac, im_matrix, T2, zero, &
                             T1, filter_eps=filter_eps)
         Tfac = one
         IF (MOD(i, 2) == 1) Tfac = -Tfac
         CALL dbcsr_add(Tres_re, T1, one, Tfac)
      END DO

      !Square the matrices, due to the scaling and squaring procedure
      IF (nsquare .GT. 0) THEN
         DO i = 1, nsquare
            CALL cp_complex_dbcsr_gemm_3("N", "N", one, Tres_re, Tres_im, &
                                         Tres_re, Tres_im, zero, exp_H(1)%matrix, exp_H(2)%matrix, &
                                         filter_eps=filter_eps)
            CALL dbcsr_copy(Tres_re, exp_H(1)%matrix)
            CALL dbcsr_copy(Tres_im, exp_H(2)%matrix)
         END DO
      ELSE
         CALL dbcsr_copy(exp_H(1)%matrix, Tres_re)
         CALL dbcsr_copy(exp_H(2)%matrix, Tres_im)
      END IF
      CALL dbcsr_deallocate_matrix(T1)
      CALL dbcsr_deallocate_matrix(T2)
      CALL dbcsr_deallocate_matrix(Tres_re)
      CALL dbcsr_deallocate_matrix(Tres_im)

      CALL timestop(handle)

   END SUBROUTINE taylor_only_imaginary_dbcsr

! **************************************************************************************************
!> \brief subroutine for general complex matrix exponentials
!>        on input a separate cp_fm_type for real and complex part
!>        on output a size 2 cp_fm_p_type, first element is the real part of
!>        the exponential second the imaginary
!> \param exp_H ...
!> \param re_part ...
!> \param im_part ...
!> \param nsquare ...
!> \param ntaylor ...
!> \param filter_eps ...
!> \author Samuel Andermatt (02.2014)
! **************************************************************************************************
   SUBROUTINE taylor_full_complex_dbcsr(exp_H, re_part, im_part, nsquare, ntaylor, filter_eps)
      TYPE(dbcsr_p_type), DIMENSION(2)                   :: exp_H
      TYPE(dbcsr_type), POINTER                          :: re_part, im_part
      INTEGER, INTENT(in)                                :: nsquare, ntaylor
      REAL(KIND=dp), INTENT(in)                          :: filter_eps

      CHARACTER(len=*), PARAMETER :: routineN = 'taylor_full_complex_dbcsr'
      COMPLEX(KIND=dp), PARAMETER                        :: one = (1.0_dp, 0.0_dp), &
                                                            zero = (0.0_dp, 0.0_dp)

      COMPLEX(KIND=dp)                                   :: square_fac
      INTEGER                                            :: handle, i
      TYPE(dbcsr_type), POINTER                          :: T1, T2, T3, Tres

      CALL timeset(routineN, handle)

      !The divider that comes from the scaling and squaring procedure
      square_fac = CMPLX(1.0_dp/(2.0_dp**REAL(nsquare, dp)), 0.0_dp, KIND=dp)

      !Allocate work matrices
      NULLIFY (T1)
      ALLOCATE (T1)
      CALL dbcsr_create(T1, template=re_part, matrix_type="N", &
                        data_type=dbcsr_type_complex_8)
      NULLIFY (T2)
      ALLOCATE (T2)
      CALL dbcsr_create(T2, template=re_part, matrix_type="N", &
                        data_type=dbcsr_type_complex_8)
      NULLIFY (T3)
      ALLOCATE (T3)
      CALL dbcsr_create(T3, template=re_part, matrix_type="N", &
                        data_type=dbcsr_type_complex_8)
      NULLIFY (Tres)
      ALLOCATE (Tres)
      CALL dbcsr_create(Tres, template=re_part, matrix_type="N", &
                        data_type=dbcsr_type_complex_8)

      !Fuse the input matrices to a single complex matrix
      CALL dbcsr_copy(T3, re_part)
      CALL dbcsr_copy(Tres, im_part) !will later on be set back to zero
      CALL dbcsr_scale(Tres, CMPLX(0.0_dp, 1.0_dp, KIND=dp))
      CALL dbcsr_add(T3, Tres, one, one)

      !Create the unit matrices
      CALL dbcsr_set(T1, zero)
      CALL dbcsr_add_on_diag(T1, one)
      CALL dbcsr_set(Tres, zero)
      CALL dbcsr_add_on_diag(Tres, one)

      DO i = 1, ntaylor
         CALL dbcsr_scale(T1, one/CMPLX(i*1.0_dp, 0.0_dp, KIND=dp))
         CALL dbcsr_filter(T1, filter_eps)
         CALL dbcsr_multiply("N", "N", square_fac, T1, T3, &
                             zero, T2, filter_eps=filter_eps)
         CALL dbcsr_add(Tres, T2, one, one)
         CALL dbcsr_copy(T1, T2)
      END DO

      IF (nsquare .GT. 0) THEN
         DO i = 1, nsquare
            CALL dbcsr_multiply("N", "N", one, Tres, Tres, zero, &
                                T2, filter_eps=filter_eps)
            CALL dbcsr_copy(Tres, T2)
         END DO
      END IF

      CALL dbcsr_copy(exp_H(1)%matrix, Tres, keep_imaginary=.FALSE.)
      CALL dbcsr_scale(Tres, CMPLX(0.0_dp, -1.0_dp, KIND=dp))
      CALL dbcsr_copy(exp_H(2)%matrix, Tres, keep_imaginary=.FALSE.)

      CALL dbcsr_deallocate_matrix(T1)
      CALL dbcsr_deallocate_matrix(T2)
      CALL dbcsr_deallocate_matrix(T3)
      CALL dbcsr_deallocate_matrix(Tres)

      CALL timestop(handle)

   END SUBROUTINE taylor_full_complex_dbcsr

! **************************************************************************************************
!> \brief  The Baker-Campbell-Hausdorff expansion for a purely imaginary exponent (e.g. rtp)
!>         Works for a non unitary propagator, because the density matrix is hermitian
!> \param propagator The exponent of the matrix exponential
!> \param density_re Real part of the density matrix
!> \param density_im Imaginary part of the density matrix
!> \param filter_eps The filtering threshold for all matrices
!> \param filter_eps_small ...
!> \param eps_exp The accuracy of the exponential
!> \author Samuel Andermatt (02.2014)
! **************************************************************************************************

   SUBROUTINE bch_expansion_imaginary_propagator(propagator, density_re, density_im, filter_eps, filter_eps_small, eps_exp)
      TYPE(dbcsr_type), POINTER                          :: propagator, density_re, density_im
      REAL(KIND=dp), INTENT(in)                          :: filter_eps, filter_eps_small, eps_exp

      CHARACTER(len=*), PARAMETER :: routineN = 'bch_expansion_imaginary_propagator'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, unit_nr
      LOGICAL                                            :: convergence
      REAL(KIND=dp)                                      :: alpha, max_alpha, prefac
      TYPE(dbcsr_type), POINTER                          :: comm, comm2, tmp, tmp2

      CALL timeset(routineN, handle)

      unit_nr = cp_logger_get_default_io_unit()

      NULLIFY (tmp)
      ALLOCATE (tmp)
      CALL dbcsr_create(tmp, template=propagator)
      NULLIFY (tmp2)
      ALLOCATE (tmp2)
      CALL dbcsr_create(tmp2, template=propagator)
      NULLIFY (comm)
      ALLOCATE (comm)
      CALL dbcsr_create(comm, template=propagator)
      NULLIFY (comm2)
      ALLOCATE (comm2)
      CALL dbcsr_create(comm2, template=propagator)

      CALL dbcsr_copy(tmp, density_re)
      CALL dbcsr_copy(tmp2, density_im)

      convergence = .FALSE.
      DO i = 1, 20
         prefac = one/i
         CALL dbcsr_multiply("N", "N", -prefac, propagator, tmp2, zero, comm, &
                             filter_eps=filter_eps_small)
         CALL dbcsr_multiply("N", "N", prefac, propagator, tmp, zero, comm2, &
                             filter_eps=filter_eps_small)
         CALL dbcsr_transposed(tmp, comm)
         CALL dbcsr_transposed(tmp2, comm2)
         CALL dbcsr_add(comm, tmp, one, one)
         CALL dbcsr_add(comm2, tmp2, one, -one)
         CALL dbcsr_add(density_re, comm, one, one)
         CALL dbcsr_add(density_im, comm2, one, one)
         CALL dbcsr_copy(tmp, comm)
         CALL dbcsr_copy(tmp2, comm2)
         !check for convergence
         max_alpha = zero
         alpha = dbcsr_frobenius_norm(comm)
         IF (alpha > max_alpha) max_alpha = alpha
         alpha = dbcsr_frobenius_norm(comm2)
         IF (alpha > max_alpha) max_alpha = alpha
         IF (max_alpha < eps_exp) convergence = .TRUE.
         IF (convergence) THEN
            IF (unit_nr > 0) WRITE (UNIT=unit_nr, FMT="((T3,A,I2,A))") &
               "BCH converged after ", i, " steps"
            EXIT
         END IF
      END DO

      CALL dbcsr_filter(density_re, filter_eps)
      CALL dbcsr_filter(density_im, filter_eps)

      IF (.NOT. convergence) &
         CPWARN("BCH method did not converge")

      CALL dbcsr_deallocate_matrix(tmp)
      CALL dbcsr_deallocate_matrix(tmp2)
      CALL dbcsr_deallocate_matrix(comm)
      CALL dbcsr_deallocate_matrix(comm2)

      CALL timestop(handle)

   END SUBROUTINE

! **************************************************************************************************
!> \brief  The Baker-Campbell-Hausdorff expansion for a complex exponent (e.g. rtp)
!>         Works for a non unitary propagator, because the density matrix is hermitian
!> \param propagator_re Real part of the exponent
!> \param propagator_im Imaginary part of the exponent
!> \param density_re Real part of the density matrix
!> \param density_im Imaginary part of the density matrix
!> \param filter_eps The filtering threshold for all matrices
!> \param filter_eps_small ...
!> \param eps_exp The accuracy of the exponential
!> \author Samuel Andermatt (02.2014)
! **************************************************************************************************

   SUBROUTINE bch_expansion_complex_propagator(propagator_re, propagator_im, density_re, density_im, filter_eps, &
                                               filter_eps_small, eps_exp)
      TYPE(dbcsr_type), POINTER                          :: propagator_re, propagator_im, &
                                                            density_re, density_im
      REAL(KIND=dp), INTENT(in)                          :: filter_eps, filter_eps_small, eps_exp

      CHARACTER(len=*), PARAMETER :: routineN = 'bch_expansion_complex_propagator'
      REAL(KIND=dp), PARAMETER                           :: one = 1.0_dp, zero = 0.0_dp

      INTEGER                                            :: handle, i, unit_nr
      LOGICAL                                            :: convergence
      REAL(KIND=dp)                                      :: alpha, max_alpha, prefac
      TYPE(dbcsr_type), POINTER                          :: comm, comm2, tmp, tmp2

      CALL timeset(routineN, handle)

      unit_nr = cp_logger_get_default_io_unit()

      NULLIFY (tmp)
      ALLOCATE (tmp)
      CALL dbcsr_create(tmp, template=propagator_re)
      NULLIFY (tmp2)
      ALLOCATE (tmp2)
      CALL dbcsr_create(tmp2, template=propagator_re)
      NULLIFY (comm)
      ALLOCATE (comm)
      CALL dbcsr_create(comm, template=propagator_re)
      NULLIFY (comm2)
      ALLOCATE (comm2)
      CALL dbcsr_create(comm2, template=propagator_re)

      CALL dbcsr_copy(tmp, density_re)
      CALL dbcsr_copy(tmp2, density_im)

      convergence = .FALSE.

      DO i = 1, 20
         prefac = one/i
         CALL cp_complex_dbcsr_gemm_3("N", "N", prefac, propagator_re, propagator_im, &
                                      tmp, tmp2, zero, comm, comm2, filter_eps=filter_eps_small)
         CALL dbcsr_transposed(tmp, comm)
         CALL dbcsr_transposed(tmp2, comm2)
         CALL dbcsr_add(comm, tmp, one, one)
         CALL dbcsr_add(comm2, tmp2, one, -one)
         CALL dbcsr_add(density_re, comm, one, one)
         CALL dbcsr_add(density_im, comm2, one, one)
         CALL dbcsr_copy(tmp, comm)
         CALL dbcsr_copy(tmp2, comm2)
         !check for convergence
         max_alpha = zero
         alpha = dbcsr_frobenius_norm(comm)
         IF (alpha > max_alpha) max_alpha = alpha
         alpha = dbcsr_frobenius_norm(comm2)
         IF (alpha > max_alpha) max_alpha = alpha
         IF (max_alpha < eps_exp) convergence = .TRUE.
         IF (convergence) THEN
            IF (unit_nr > 0) WRITE (UNIT=unit_nr, FMT="((T3,A,I2,A))") &
               "BCH converged after ", i, " steps"
            EXIT
         END IF
      END DO

      CALL dbcsr_filter(density_re, filter_eps)
      CALL dbcsr_filter(density_im, filter_eps)

      IF (.NOT. convergence) &
         CPWARN("BCH method did not converge ")

      CALL dbcsr_deallocate_matrix(tmp)
      CALL dbcsr_deallocate_matrix(tmp2)
      CALL dbcsr_deallocate_matrix(comm)
      CALL dbcsr_deallocate_matrix(comm2)

      CALL timestop(handle)

   END SUBROUTINE

END MODULE ls_matrix_exp
