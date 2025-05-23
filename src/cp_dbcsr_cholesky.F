!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief   Interface to (sca)lapack for the Cholesky based procedures
!> \author  VW
!> \date    2009-09-08
!> \version 0.8
!>
!> <b>Modification history:</b>
!> - Created 2009-09-08
! **************************************************************************************************
MODULE cp_dbcsr_cholesky
   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr
   USE cp_fm_basic_linalg,              ONLY: cp_fm_upper_to_full
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_get_info,&
                                              dbcsr_type
   USE kinds,                           ONLY: dp,&
                                              sp
#include "base/base_uses.f90"

   IMPLICIT NONE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_dbcsr_cholesky'

   PUBLIC :: cp_dbcsr_cholesky_decompose, cp_dbcsr_cholesky_invert, &
             cp_dbcsr_cholesky_restore

   PRIVATE

CONTAINS

! **************************************************************************************************
!> \brief used to replace a symmetric positive def. matrix M with its cholesky
!>      decomposition U: M = U^T * U, with U upper triangular
!> \param matrix the matrix to replace with its cholesky decomposition
!> \param n the number of row (and columns) of the matrix &
!>        (defaults to the min(size(matrix)))
!> \param para_env ...
!> \param blacs_env ...
!> \par History
!>      05.2002 created [JVdV]
!>      12.2002 updated, added n optional parm [fawzi]
!> \author Joost
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_cholesky_decompose(matrix, n, para_env, blacs_env)
      TYPE(dbcsr_type)                      :: matrix
      INTEGER, INTENT(in), OPTIONAL            :: n
      TYPE(cp_para_env_type), POINTER          :: para_env
      TYPE(cp_blacs_env_type), POINTER         :: blacs_env

      CHARACTER(len=*), PARAMETER :: routineN = 'cp_dbcsr_cholesky_decompose'

      INTEGER                                  :: handle, info, my_n, &
                                                  nfullcols_total, &
                                                  nfullrows_total
      REAL(KIND=dp), DIMENSION(:, :), POINTER  :: a
      REAL(KIND=sp), DIMENSION(:, :), POINTER  :: a_sp
      TYPE(cp_fm_struct_type), POINTER         :: fm_struct
      TYPE(cp_fm_type)                :: fm_matrix
#if defined(__SCALAPACK)
      INTEGER, DIMENSION(9)                    :: desca
#endif

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct)
      CALL dbcsr_get_info(matrix, nfullrows_total=nfullrows_total, nfullcols_total=nfullcols_total)

      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullcols_total, para_env=para_env)
      CALL cp_fm_create(fm_matrix, fm_struct, name="fm_matrix")
      CALL cp_fm_struct_release(fm_struct)

      CALL copy_dbcsr_to_fm(matrix, fm_matrix)

      my_n = MIN(fm_matrix%matrix_struct%nrow_global, &
                 fm_matrix%matrix_struct%ncol_global)
      IF (PRESENT(n)) THEN
         CPASSERT(n <= my_n)
         my_n = n
      END IF

      a => fm_matrix%local_data
      a_sp => fm_matrix%local_data_sp

#if defined(__SCALAPACK)
      desca(:) = fm_matrix%matrix_struct%descriptor(:)

      IF (fm_matrix%use_sp) THEN
         CALL pspotrf('U', my_n, a_sp(1, 1), 1, 1, desca, info)
      ELSE
         CALL pdpotrf('U', my_n, a(1, 1), 1, 1, desca, info)
      END IF

#else

      IF (fm_matrix%use_sp) THEN
         CALL spotrf('U', my_n, a_sp(1, 1), SIZE(a_sp, 1), info)
      ELSE
         CALL dpotrf('U', my_n, a(1, 1), SIZE(a, 1), info)
      END IF

#endif

      IF (info /= 0) &
         CPABORT("Cholesky decomposition failed. Matrix ill conditioned ?")

      CALL copy_fm_to_dbcsr(fm_matrix, matrix)

      CALL cp_fm_release(fm_matrix)

      CALL timestop(handle)

   END SUBROUTINE cp_dbcsr_cholesky_decompose

! **************************************************************************************************
!> \brief used to replace the cholesky decomposition by the inverse
!> \param matrix the matrix to invert (must be an upper triangular matrix)
!> \param n size of the matrix to invert (defaults to the min(size(matrix)))
!> \param para_env ...
!> \param blacs_env ...
!> \param upper_to_full ...
!> \par History
!>      05.2002 created [JVdV]
!> \author Joost VandeVondele
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_cholesky_invert(matrix, n, para_env, blacs_env, upper_to_full)
      TYPE(dbcsr_type)                           :: matrix
      INTEGER, INTENT(in), OPTIONAL             :: n
      TYPE(cp_para_env_type), POINTER           :: para_env
      TYPE(cp_blacs_env_type), POINTER          :: blacs_env
      LOGICAL, INTENT(IN)                       :: upper_to_full

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_cholesky_invert'

      REAL(KIND=dp), DIMENSION(:, :), POINTER  :: a
      REAL(KIND=sp), DIMENSION(:, :), POINTER  :: a_sp
      INTEGER                                   :: info, handle
      INTEGER                                   :: my_n, nfullrows_total, nfullcols_total
      TYPE(cp_fm_type)                 :: fm_matrix, fm_matrix_tmp
      TYPE(cp_fm_struct_type), POINTER          :: fm_struct
#if defined(__SCALAPACK)
      INTEGER, DIMENSION(9)                     :: desca
#endif

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct)
      CALL dbcsr_get_info(matrix, nfullrows_total=nfullrows_total, nfullcols_total=nfullcols_total)

      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullrows_total, para_env=para_env)
      CALL cp_fm_create(fm_matrix, fm_struct, name="fm_matrix")
      CALL cp_fm_struct_release(fm_struct)

      CALL copy_dbcsr_to_fm(matrix, fm_matrix)

      my_n = MIN(fm_matrix%matrix_struct%nrow_global, &
                 fm_matrix%matrix_struct%ncol_global)
      IF (PRESENT(n)) THEN
         CPASSERT(n <= my_n)
         my_n = n
      END IF

      a => fm_matrix%local_data
      a_sp => fm_matrix%local_data_sp

#if defined(__SCALAPACK)

      desca(:) = fm_matrix%matrix_struct%descriptor(:)

      IF (fm_matrix%use_sp) THEN
         CALL pspotri('U', my_n, a_sp(1, 1), 1, 1, desca, info)
      ELSE
         CALL pdpotri('U', my_n, a(1, 1), 1, 1, desca, info)
      END IF

#else

      IF (fm_matrix%use_sp) THEN
         CALL spotri('U', my_n, a_sp(1, 1), SIZE(a_sp, 1), info)
      ELSE
         CALL dpotri('U', my_n, a(1, 1), SIZE(a, 1), info)
      END IF

#endif

      CPASSERT(info == 0)

      IF (upper_to_full) THEN
         CALL cp_fm_create(fm_matrix_tmp, fm_matrix%matrix_struct, name="fm_matrix_tmp")
         CALL cp_fm_upper_to_full(fm_matrix, fm_matrix_tmp)
         CALL cp_fm_release(fm_matrix_tmp)
      END IF

      CALL copy_fm_to_dbcsr(fm_matrix, matrix)

      CALL cp_fm_release(fm_matrix)

      CALL timestop(handle)

   END SUBROUTINE cp_dbcsr_cholesky_invert

! **************************************************************************************************
!> \brief ...
!> \param matrix ...
!> \param neig ...
!> \param matrixb ...
!> \param matrixout ...
!> \param op ...
!> \param pos ...
!> \param transa ...
!> \param para_env ...
!> \param blacs_env ...
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_cholesky_restore(matrix, neig, matrixb, matrixout, op, pos, transa, &
                                        para_env, blacs_env)
      TYPE(dbcsr_type)                                :: matrix, matrixb, matrixout
      INTEGER, INTENT(IN)                            :: neig
      CHARACTER(LEN=*), INTENT(IN)           :: op
      CHARACTER(LEN=*), INTENT(IN), OPTIONAL :: pos
      CHARACTER(LEN=*), INTENT(IN), OPTIONAL :: transa
      TYPE(cp_para_env_type), POINTER                :: para_env
      TYPE(cp_blacs_env_type), POINTER               :: blacs_env

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_cholesky_restore'

      REAL(KIND=dp), DIMENSION(:, :), POINTER  :: a, b, out
      REAL(KIND=sp), DIMENSION(:, :), POINTER  :: a_sp, b_sp, out_sp
      INTEGER                                   :: itype, handle
      INTEGER                                   :: n
      REAL(KIND=dp)                           :: alpha
      INTEGER                                   :: myprow, mypcol, nfullrows_total, &
                                                   nfullcols_total
      TYPE(cp_blacs_env_type), POINTER          :: context
      CHARACTER                                 :: chol_pos, chol_transa
      TYPE(cp_fm_type)                 :: fm_matrix, fm_matrixb, fm_matrixout
      TYPE(cp_fm_struct_type), POINTER          :: fm_struct
#if defined(__SCALAPACK)
      INTEGER                                   :: i
      INTEGER, DIMENSION(9)                     :: desca, descb, descout
#endif

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct)

      CALL dbcsr_get_info(matrix, nfullrows_total=nfullrows_total, nfullcols_total=nfullcols_total)
      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullcols_total, para_env=para_env)
      CALL cp_fm_create(fm_matrix, fm_struct, name="fm_matrix")
      CALL cp_fm_struct_release(fm_struct)

      CALL dbcsr_get_info(matrixb, nfullrows_total=nfullrows_total, nfullcols_total=nfullcols_total)
      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullcols_total, para_env=para_env)
      CALL cp_fm_create(fm_matrixb, fm_struct, name="fm_matrixb")
      CALL cp_fm_struct_release(fm_struct)

      CALL dbcsr_get_info(matrixout, nfullrows_total=nfullrows_total, nfullcols_total=nfullcols_total)
      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullcols_total, para_env=para_env)
      CALL cp_fm_create(fm_matrixout, fm_struct, name="fm_matrixout")
      CALL cp_fm_struct_release(fm_struct)

      CALL copy_dbcsr_to_fm(matrix, fm_matrix)
      CALL copy_dbcsr_to_fm(matrixb, fm_matrixb)
      !CALL copy_dbcsr_to_fm(matrixout, fm_matrixout)

      context => fm_matrix%matrix_struct%context
      myprow = context%mepos(1)
      mypcol = context%mepos(2)
      n = fm_matrix%matrix_struct%nrow_global
      itype = 1
      IF (op /= "SOLVE" .AND. op /= "MULTIPLY") &
         CPABORT("wrong argument op")

      IF (PRESENT(pos)) THEN
         SELECT CASE (pos)
         CASE ("LEFT")
            chol_pos = 'L'
         CASE ("RIGHT")
            chol_pos = 'R'
         CASE DEFAULT
            CPABORT("wrong argument pos")
         END SELECT
      ELSE
         chol_pos = 'L'
      END IF

      chol_transa = 'N'
      IF (PRESENT(transa)) chol_transa = transa

      IF ((fm_matrix%use_sp .NEQV. fm_matrixb%use_sp) .OR. (fm_matrix%use_sp .NEQV. fm_matrixout%use_sp)) &
         CPABORT("not the same precision")

      ! notice b is the cholesky guy
      a => fm_matrix%local_data
      b => fm_matrixb%local_data
      out => fm_matrixout%local_data
      a_sp => fm_matrix%local_data_sp
      b_sp => fm_matrixb%local_data_sp
      out_sp => fm_matrixout%local_data_sp

#if defined(__SCALAPACK)

      desca(:) = fm_matrix%matrix_struct%descriptor(:)
      descb(:) = fm_matrixb%matrix_struct%descriptor(:)
      descout(:) = fm_matrixout%matrix_struct%descriptor(:)
      alpha = 1.0_dp
      DO i = 1, neig
         IF (fm_matrix%use_sp) THEN
            CALL pscopy(n, a_sp(1, 1), 1, i, desca, 1, out_sp(1, 1), 1, i, descout, 1)
         ELSE
            CALL pdcopy(n, a(1, 1), 1, i, desca, 1, out(1, 1), 1, i, descout, 1)
         END IF
      END DO
      IF (op .EQ. "SOLVE") THEN
         IF (fm_matrix%use_sp) THEN
            CALL pstrsm(chol_pos, 'U', chol_transa, 'N', n, neig, REAL(alpha, sp), b_sp(1, 1), 1, 1, descb, &
                        out_sp(1, 1), 1, 1, descout)
         ELSE
            CALL pdtrsm(chol_pos, 'U', chol_transa, 'N', n, neig, alpha, b(1, 1), 1, 1, descb, out(1, 1), 1, 1, descout)
         END IF
      ELSE
         IF (fm_matrix%use_sp) THEN
            CALL pstrmm(chol_pos, 'U', chol_transa, 'N', n, neig, REAL(alpha, sp), b_sp(1, 1), 1, 1, descb, &
                        out_sp(1, 1), 1, 1, descout)
         ELSE
            CALL pdtrmm(chol_pos, 'U', chol_transa, 'N', n, neig, alpha, b(1, 1), 1, 1, descb, out(1, 1), 1, 1, descout)
         END IF
      END IF
#else

      alpha = 1.0_dp
      IF (fm_matrix%use_sp) THEN
         CALL scopy(neig*n, a_sp(1, 1), 1, out_sp(1, 1), 1)
      ELSE
         CALL dcopy(neig*n, a(1, 1), 1, out(1, 1), 1)
      END IF
      IF (op .EQ. "SOLVE") THEN
         IF (fm_matrix%use_sp) THEN
            CALL strsm(chol_pos, 'U', chol_transa, 'N', n, neig, REAL(alpha, sp), b_sp(1, 1), SIZE(b_sp, 1), out_sp(1, 1), n)
         ELSE
            CALL dtrsm(chol_pos, 'U', chol_transa, 'N', n, neig, alpha, b(1, 1), SIZE(b, 1), out(1, 1), n)
         END IF
      ELSE
         IF (fm_matrix%use_sp) THEN
            CALL strmm(chol_pos, 'U', chol_transa, 'N', n, neig, REAL(alpha, sp), b_sp(1, 1), n, out_sp(1, 1), n)
         ELSE
            CALL dtrmm(chol_pos, 'U', chol_transa, 'N', n, neig, alpha, b(1, 1), n, out(1, 1), n)
         END IF
      END IF

#endif

      CALL copy_fm_to_dbcsr(fm_matrixout, matrixout)

      CALL cp_fm_release(fm_matrix)
      CALL cp_fm_release(fm_matrixb)
      CALL cp_fm_release(fm_matrixout)

      CALL timestop(handle)

   END SUBROUTINE cp_dbcsr_cholesky_restore

END MODULE cp_dbcsr_cholesky

