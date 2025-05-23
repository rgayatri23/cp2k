!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief types of  preconditioners
!> \par History
!>      Separate types from construction and application
!> \author Joost VandeVondele (09.2002)
! **************************************************************************************************
MODULE preconditioner_types
   USE cp_blacs_env,                    ONLY: cp_blacs_env_release,&
                                              cp_blacs_env_retain,&
                                              cp_blacs_env_type
   USE cp_fm_types,                     ONLY: cp_fm_release,&
                                              cp_fm_type
   USE cp_para_env,                     ONLY: cp_para_env_release,&
                                              cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_deallocate_matrix,&
                                              dbcsr_p_type,&
                                              dbcsr_release_p,&
                                              dbcsr_type
   USE input_constants,                 ONLY: cholesky_reduce,&
                                              ot_precond_solver_default
   USE kinds,                           ONLY: dp
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'preconditioner_types'

   PUBLIC  :: preconditioner_type, preconditioner_p_type
   PUBLIC  :: init_preconditioner
   PUBLIC  :: preconditioner_in_use
   PUBLIC  :: destroy_preconditioner

! **************************************************************************************************
   TYPE preconditioner_type
!    PRIVATE
      TYPE(dbcsr_type), POINTER :: sparse_matrix
      TYPE(cp_fm_type), POINTER :: fm
      TYPE(dbcsr_type), POINTER           :: dbcsr_matrix
      TYPE(dbcsr_type), POINTER           :: max_ev_vector
      TYPE(dbcsr_type), POINTER           :: min_ev_vector
      TYPE(dbcsr_p_type), POINTER, DIMENSION(:) :: inverse_history
      TYPE(cp_para_env_type), POINTER   :: para_env
      TYPE(cp_blacs_env_type), POINTER   :: ctxt
      INTEGER :: in_use, solver, ihistory, cholesky_use
      REAL(KIND=dp), DIMENSION(:), POINTER :: occ_evals, full_evals
      REAL(KIND=dp) :: energy_gap
      REAL(KIND=dp) :: condition_num
   END TYPE preconditioner_type

! **************************************************************************************************
   TYPE preconditioner_p_type
      TYPE(preconditioner_type), POINTER :: preconditioner
   END TYPE preconditioner_p_type

CONTAINS

! **************************************************************************************************

! **************************************************************************************************
!> \brief ...
!> \param preconditioner ...
!> \return ...
! **************************************************************************************************
   FUNCTION preconditioner_in_use(preconditioner)
      TYPE(preconditioner_type)                          :: preconditioner
      LOGICAL                                            :: preconditioner_in_use

      preconditioner_in_use = .NOT. (preconditioner%in_use .EQ. 0)
   END FUNCTION

! **************************************************************************************************
!> \brief ...
!> \param preconditioner_env ...
!> \param para_env ...
!> \param blacs_env ...
! **************************************************************************************************
   SUBROUTINE init_preconditioner(preconditioner_env, para_env, blacs_env)

      TYPE(preconditioner_type)                          :: preconditioner_env
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env

      NULLIFY (preconditioner_env%sparse_matrix)
      NULLIFY (preconditioner_env%fm)
      NULLIFY (preconditioner_env%dbcsr_matrix)
      NULLIFY (preconditioner_env%occ_evals)
      NULLIFY (preconditioner_env%full_evals)
      NULLIFY (preconditioner_env%inverse_history)
      NULLIFY (preconditioner_env%max_ev_vector)
      NULLIFY (preconditioner_env%min_ev_vector)
      preconditioner_env%solver = ot_precond_solver_default
      preconditioner_env%para_env => para_env
      preconditioner_env%ctxt => blacs_env
      !inverse is used for filtering in update set it to something huge to
      ! avoid filtering if the information is not available
      preconditioner_env%condition_num = -1.0_dp
      preconditioner_env%ihistory = 0

      CALL cp_para_env_retain(preconditioner_env%para_env)
      CALL cp_blacs_env_retain(preconditioner_env%ctxt)

   END SUBROUTINE init_preconditioner

! **************************************************************************************************
!> \brief ...
!> \param preconditioner_env ...
! **************************************************************************************************
   SUBROUTINE destroy_preconditioner(preconditioner_env)

      TYPE(preconditioner_type)                          :: preconditioner_env

      CHARACTER(len=*), PARAMETER :: routineN = 'destroy_preconditioner'

      INTEGER                                            :: handle, i

      CALL timeset(routineN, handle)

      IF (ASSOCIATED(preconditioner_env%sparse_matrix)) THEN
         CALL dbcsr_deallocate_matrix(preconditioner_env%sparse_matrix)
         NULLIFY (preconditioner_env%sparse_matrix)
      END IF

      IF (ASSOCIATED(preconditioner_env%fm)) THEN
         CALL cp_fm_release(preconditioner_env%fm)
         DEALLOCATE (preconditioner_env%fm)
         NULLIFY (preconditioner_env%fm)
      END IF
      IF (ASSOCIATED(preconditioner_env%dbcsr_matrix)) THEN
         CALL dbcsr_release_p(preconditioner_env%dbcsr_matrix)
      END IF
      IF (ASSOCIATED(preconditioner_env%max_ev_vector)) THEN
         CALL dbcsr_release_p(preconditioner_env%max_ev_vector)
      END IF
      IF (ASSOCIATED(preconditioner_env%min_ev_vector)) THEN
         CALL dbcsr_release_p(preconditioner_env%min_ev_vector)
      END IF
      IF (ASSOCIATED(preconditioner_env%occ_evals)) THEN
         DEALLOCATE (preconditioner_env%occ_evals)
      END IF
      IF (ASSOCIATED(preconditioner_env%full_evals)) THEN
         DEALLOCATE (preconditioner_env%full_evals)
      END IF
      IF (ASSOCIATED(preconditioner_env%inverse_history)) THEN
         DO i = 1, SIZE(preconditioner_env%inverse_history)
            CALL dbcsr_release_p(preconditioner_env%inverse_history(i)%matrix)
         END DO
         DEALLOCATE (preconditioner_env%inverse_history)
      END IF
      CALL cp_para_env_release(preconditioner_env%para_env)
      CALL cp_blacs_env_release(preconditioner_env%ctxt)

      preconditioner_env%in_use = 0
      preconditioner_env%cholesky_use = cholesky_reduce

      CALL timestop(handle)

   END SUBROUTINE destroy_preconditioner

END MODULE preconditioner_types

