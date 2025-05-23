!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief   Interface to (sca)lapack for the Cholesky based procedures
!> \author  VW
!> \date    2009-11-09
!> \version 0.8
!>
!> <b>Modification history:</b>
!> - Created 2009-11-09
! **************************************************************************************************
MODULE cp_dbcsr_diag

   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_cfm_diag,                     ONLY: cp_cfm_heevd
   USE cp_cfm_types,                    ONLY: cp_cfm_create,&
                                              cp_cfm_release,&
                                              cp_cfm_type
   USE cp_dbcsr_operations,             ONLY: copy_cfm_to_dbcsr,&
                                              copy_dbcsr_to_cfm,&
                                              copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr
   USE cp_fm_diag,                      ONLY: choose_eigv_solver,&
                                              cp_fm_power,&
                                              cp_fm_syevx
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_get_info,&
                                              dbcsr_type
   USE kinds,                           ONLY: dp
#include "base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_dbcsr_diag'

   ! Public subroutines

   PUBLIC :: cp_dbcsr_syevd, &
             cp_dbcsr_syevx, &
             cp_dbcsr_heevd, &
             cp_dbcsr_power

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param matrix ...
!> \param eigenvectors ...
!> \param eigenvalues ...
!> \param para_env ...
!> \param blacs_env ...
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_syevd(matrix, eigenvectors, eigenvalues, para_env, blacs_env)

      ! Computes all eigenvalues and vectors of a real symmetric matrix
      ! should be quite a bit faster than syevx for that case
      ! especially in parallel with thightly clustered evals
      ! needs more workspace in the worst case, but much better distributed

      TYPE(dbcsr_type)                                   :: matrix, eigenvectors
      REAL(KIND=dp), DIMENSION(:), INTENT(OUT)           :: eigenvalues
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'cp_dbcsr_syevd'

      INTEGER                                            :: handle, nfullrows_total
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct
      TYPE(cp_fm_type)                                   :: fm_eigenvectors, fm_matrix

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct)
      CALL dbcsr_get_info(matrix, nfullrows_total=nfullrows_total)

      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullrows_total, para_env=para_env)
      CALL cp_fm_create(fm_matrix, fm_struct, name="fm_matrix")
      CALL cp_fm_create(fm_eigenvectors, fm_struct, name="fm_eigenvectors")
      CALL cp_fm_struct_release(fm_struct)

      CALL copy_dbcsr_to_fm(matrix, fm_matrix)

      CALL choose_eigv_solver(fm_matrix, fm_eigenvectors, eigenvalues)

      CALL copy_fm_to_dbcsr(fm_eigenvectors, eigenvectors)

      CALL cp_fm_release(fm_matrix)
      CALL cp_fm_release(fm_eigenvectors)

      CALL timestop(handle)

   END SUBROUTINE cp_dbcsr_syevd

! **************************************************************************************************
!> \brief   compute eigenvalues and optionally eigenvectors of a real symmetric matrix using scalapack.
!>          If eigenvectors are required this routine will replicate a full matrix on each CPU...
!>          if more than a handful of vectors are needed, use cp_dbcsr_syevd instead
!> \param matrix ...
!> \param eigenvectors ...
!> \param eigenvalues ...
!> \param neig ...
!> \param work_syevx ...
!> \param para_env ...
!> \param blacs_env ...
!> \par     matrix is supposed to be in upper triangular form, and overwritten by this routine
!>          neig   is the number of vectors needed (default all)
!>          work_syevx evec calculation only, is the fraction of the working buffer allowed (1.0 use full buffer)
!>                     reducing this saves time, but might cause the routine to fail
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_syevx(matrix, eigenvectors, eigenvalues, neig, work_syevx, &
                             para_env, blacs_env)

      ! Diagonalise the symmetric n by n matrix using the LAPACK library.

      TYPE(dbcsr_type), POINTER                          :: matrix
      TYPE(dbcsr_type), OPTIONAL, POINTER                :: eigenvectors
      REAL(KIND=dp), DIMENSION(:), INTENT(OUT)           :: eigenvalues
      INTEGER, INTENT(IN), OPTIONAL                      :: neig
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: work_syevx
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'cp_dbcsr_syevx'

      INTEGER                                            :: handle, n, neig_local
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct
      TYPE(cp_fm_type)                                   :: fm_eigenvectors, fm_matrix

      CALL timeset(routineN, handle)

      ! by default all
      CALL dbcsr_get_info(matrix, nfullrows_total=n)
      neig_local = n
      IF (PRESENT(neig)) neig_local = neig
      IF (neig_local == 0) RETURN

      NULLIFY (fm_struct)
      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=n, &
                               ncol_global=n, para_env=para_env)
      CALL cp_fm_create(fm_matrix, fm_struct, name="fm_matrix")

      CALL copy_dbcsr_to_fm(matrix, fm_matrix)

      IF (PRESENT(eigenvectors)) THEN
         CALL cp_fm_create(fm_eigenvectors, fm_struct, name="fm_eigenvectors")
         CALL cp_fm_syevx(fm_matrix, fm_eigenvectors, eigenvalues, neig, work_syevx)
         CALL copy_fm_to_dbcsr(fm_eigenvectors, eigenvectors)
         CALL cp_fm_release(fm_eigenvectors)
      ELSE
         CALL cp_fm_syevx(fm_matrix, eigenvalues=eigenvalues, neig=neig, work_syevx=work_syevx)
      END IF

      CALL cp_fm_struct_release(fm_struct)
      CALL cp_fm_release(fm_matrix)

      CALL timestop(handle)

   END SUBROUTINE cp_dbcsr_syevx

! **************************************************************************************************
!> \brief ...
!> \param matrix ...
!> \param eigenvectors ...
!> \param eigenvalues ...
!> \param para_env ...
!> \param blacs_env ...
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_heevd(matrix, eigenvectors, eigenvalues, para_env, blacs_env)

      TYPE(dbcsr_type)                                   :: matrix
      TYPE(dbcsr_type), OPTIONAL, POINTER                :: eigenvectors
      REAL(KIND=dp), DIMENSION(:), INTENT(OUT)           :: eigenvalues
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'cp_dbcsr_heevd'

      INTEGER                                            :: handle, nfullrows_total
      TYPE(cp_cfm_type)                                  :: fm_eigenvectors, fm_matrix
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct)
      CALL dbcsr_get_info(matrix, nfullrows_total=nfullrows_total)

      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullrows_total, para_env=para_env)
      CALL cp_cfm_create(fm_matrix, fm_struct, name="fm_matrix")
      CALL cp_cfm_create(fm_eigenvectors, fm_struct, name="fm_eigenvectors")
      CALL cp_fm_struct_release(fm_struct)

      CALL copy_dbcsr_to_cfm(matrix, fm_matrix)

      CALL cp_cfm_heevd(fm_matrix, fm_eigenvectors, eigenvalues)

      CALL copy_cfm_to_dbcsr(fm_eigenvectors, eigenvectors)

      CALL cp_cfm_release(fm_matrix)
      CALL cp_cfm_release(fm_eigenvectors)

      CALL timestop(handle)

   END SUBROUTINE cp_dbcsr_heevd

! **************************************************************************************************
!> \brief ...
!> \param matrix ...
!> \param exponent ...
!> \param threshold ...
!> \param n_dependent ...
!> \param para_env ...
!> \param blacs_env ...
!> \param verbose ...
!> \param eigenvectors ...
!> \param eigenvalues ...
! **************************************************************************************************
   SUBROUTINE cp_dbcsr_power(matrix, exponent, threshold, n_dependent, para_env, blacs_env, verbose, eigenvectors, eigenvalues)
      TYPE(dbcsr_type), INTENT(INOUT)                    :: matrix
      REAL(dp), INTENT(IN)                               :: exponent, threshold
      INTEGER, INTENT(OUT)                               :: n_dependent
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      LOGICAL, INTENT(IN), OPTIONAL                      :: verbose
      TYPE(dbcsr_type), INTENT(INOUT), OPTIONAL          :: eigenvectors
      REAL(KIND=dp), DIMENSION(2), INTENT(OUT), OPTIONAL :: eigenvalues

      CHARACTER(len=*), PARAMETER                        :: routineN = 'cp_dbcsr_power'

      INTEGER                                            :: handle, nfullrows_total
      REAL(KIND=dp), DIMENSION(2)                        :: eigenvalues_prv
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct
      TYPE(cp_fm_type)                                   :: fm_eigenvectors, fm_matrix

      CALL timeset(routineN, handle)

      NULLIFY (fm_struct)
      CALL dbcsr_get_info(matrix, nfullrows_total=nfullrows_total)

      CALL cp_fm_struct_create(fm_struct, context=blacs_env, nrow_global=nfullrows_total, &
                               ncol_global=nfullrows_total, para_env=para_env)
      CALL cp_fm_create(fm_matrix, fm_struct, name="fm_matrix")
      CALL cp_fm_create(fm_eigenvectors, fm_struct, name="fm_eigenvectors")
      CALL cp_fm_struct_release(fm_struct)

      CALL copy_dbcsr_to_fm(matrix, fm_matrix)

      CALL cp_fm_power(fm_matrix, fm_eigenvectors, exponent, threshold, n_dependent, verbose, eigenvalues_prv)

      CALL copy_fm_to_dbcsr(fm_matrix, matrix)
      CALL cp_fm_release(fm_matrix)

      IF (PRESENT(eigenvalues)) eigenvalues(:) = eigenvalues_prv
      IF (PRESENT(eigenvectors)) CALL copy_fm_to_dbcsr(fm_eigenvectors, eigenvectors)

      CALL cp_fm_release(fm_eigenvectors)

      CALL timestop(handle)

   END SUBROUTINE

END MODULE cp_dbcsr_diag
