!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief A DIIS implementation for the ALMO-based SCF methods
!> \par History
!>       2011.12 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
MODULE almo_scf_diis_types
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type
   USE dbcsr_api,                       ONLY: dbcsr_add,&
                                              dbcsr_copy,&
                                              dbcsr_create,&
                                              dbcsr_dot,&
                                              dbcsr_release,&
                                              dbcsr_set,&
                                              dbcsr_type
   USE domain_submatrix_methods,        ONLY: add_submatrices,&
                                              copy_submatrices,&
                                              init_submatrices,&
                                              release_submatrices,&
                                              set_submatrices
   USE domain_submatrix_types,          ONLY: domain_submatrix_type
   USE kinds,                           ONLY: dp
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   INTEGER, PARAMETER :: diis_error_orthogonal = 1

   INTEGER, PARAMETER :: diis_env_dbcsr = 1
   INTEGER, PARAMETER :: diis_env_domain = 2

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'almo_scf_diis_types'

   PUBLIC :: almo_scf_diis_type, &
             almo_scf_diis_init, almo_scf_diis_release, almo_scf_diis_push, &
             almo_scf_diis_extrapolate

   INTERFACE almo_scf_diis_init
      MODULE PROCEDURE almo_scf_diis_init_dbcsr
      MODULE PROCEDURE almo_scf_diis_init_domain
   END INTERFACE

   TYPE almo_scf_diis_type

      INTEGER :: diis_env_type

      INTEGER :: buffer_length
      INTEGER :: max_buffer_length
      !INTEGER, DIMENSION(:), ALLOCATABLE :: history_index

      TYPE(dbcsr_type), DIMENSION(:), ALLOCATABLE :: m_var
      TYPE(dbcsr_type), DIMENSION(:), ALLOCATABLE :: m_err

      ! first dimension is history index, second - domain index
      TYPE(domain_submatrix_type), DIMENSION(:, :), ALLOCATABLE :: d_var
      TYPE(domain_submatrix_type), DIMENSION(:, :), ALLOCATABLE :: d_err

      ! distributed matrix of error overlaps
      TYPE(domain_submatrix_type), DIMENSION(:), ALLOCATABLE     :: m_b

      ! insertion point
      INTEGER :: in_point

      ! in order to calculate the overlap between error vectors
      ! it is desirable to know tensorial properties of the error
      ! vector, e.g. convariant, contravariant, orthogonal
      INTEGER :: error_type

   END TYPE almo_scf_diis_type

CONTAINS

! **************************************************************************************************
!> \brief initializes the diis structure
!> \param diis_env ...
!> \param sample_err ...
!> \param sample_var ...
!> \param error_type ...
!> \param max_length ...
!> \par History
!>       2011.12 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE almo_scf_diis_init_dbcsr(diis_env, sample_err, sample_var, error_type, &
                                       max_length)

      TYPE(almo_scf_diis_type), INTENT(INOUT)            :: diis_env
      TYPE(dbcsr_type), INTENT(IN)                       :: sample_err, sample_var
      INTEGER, INTENT(IN)                                :: error_type, max_length

      CHARACTER(len=*), PARAMETER :: routineN = 'almo_scf_diis_init_dbcsr'

      INTEGER                                            :: handle, idomain, im, ndomains

      CALL timeset(routineN, handle)

      IF (max_length .LE. 0) THEN
         CPABORT("DIIS: max_length is less than zero")
      END IF

      diis_env%diis_env_type = diis_env_dbcsr

      diis_env%max_buffer_length = max_length
      diis_env%buffer_length = 0
      diis_env%error_type = error_type
      diis_env%in_point = 1

      ALLOCATE (diis_env%m_err(diis_env%max_buffer_length))
      ALLOCATE (diis_env%m_var(diis_env%max_buffer_length))

      ! create matrices
      DO im = 1, diis_env%max_buffer_length
         CALL dbcsr_create(diis_env%m_err(im), &
                           template=sample_err)
         CALL dbcsr_create(diis_env%m_var(im), &
                           template=sample_var)
      END DO

      ! current B matrices are only 1-by-1, they will be expanded on-the-fly
      ! only one matrix is used with dbcsr version of DIIS
      ndomains = 1
      ALLOCATE (diis_env%m_b(ndomains))
      CALL init_submatrices(diis_env%m_b)
      ! hack into d_b structure to gain full control
      diis_env%m_b(:)%domain = 100 ! arbitrary positive number
      DO idomain = 1, ndomains
         IF (diis_env%m_b(idomain)%domain .GT. 0) THEN
            ALLOCATE (diis_env%m_b(idomain)%mdata(1, 1))
            diis_env%m_b(idomain)%mdata(:, :) = 0.0_dp
         END IF
      END DO

      CALL timestop(handle)

   END SUBROUTINE almo_scf_diis_init_dbcsr

! **************************************************************************************************
!> \brief initializes the diis structure
!> \param diis_env ...
!> \param sample_err ...
!> \param error_type ...
!> \param max_length ...
!> \par History
!>       2011.12 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE almo_scf_diis_init_domain(diis_env, sample_err, error_type, &
                                        max_length)

      TYPE(almo_scf_diis_type), INTENT(INOUT)            :: diis_env
      TYPE(domain_submatrix_type), DIMENSION(:), &
         INTENT(IN)                                      :: sample_err
      INTEGER, INTENT(IN)                                :: error_type, max_length

      CHARACTER(len=*), PARAMETER :: routineN = 'almo_scf_diis_init_domain'

      INTEGER                                            :: handle, idomain, ndomains

      CALL timeset(routineN, handle)

      IF (max_length .LE. 0) THEN
         CPABORT("DIIS: max_length is less than zero")
      END IF

      diis_env%diis_env_type = diis_env_domain

      diis_env%max_buffer_length = max_length
      diis_env%buffer_length = 0
      diis_env%error_type = error_type
      diis_env%in_point = 1

      ndomains = SIZE(sample_err)

      ALLOCATE (diis_env%d_err(diis_env%max_buffer_length, ndomains))
      ALLOCATE (diis_env%d_var(diis_env%max_buffer_length, ndomains))

      ! create matrices
      CALL init_submatrices(diis_env%d_var)
      CALL init_submatrices(diis_env%d_err)

      ! current B matrices are only 1-by-1, they will be expanded on-the-fly
      ALLOCATE (diis_env%m_b(ndomains))
      CALL init_submatrices(diis_env%m_b)
      ! hack into d_b structure to gain full control
      ! distribute matrices as the err/var matrices
      diis_env%m_b(:)%domain = sample_err(:)%domain
      DO idomain = 1, ndomains
         IF (diis_env%m_b(idomain)%domain .GT. 0) THEN
            ALLOCATE (diis_env%m_b(idomain)%mdata(1, 1))
            diis_env%m_b(idomain)%mdata(:, :) = 0.0_dp
         END IF
      END DO

      CALL timestop(handle)

   END SUBROUTINE almo_scf_diis_init_domain

! **************************************************************************************************
!> \brief adds a variable-error pair to the diis structure
!> \param diis_env ...
!> \param var ...
!> \param err ...
!> \param d_var ...
!> \param d_err ...
!> \par History
!>       2011.12 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE almo_scf_diis_push(diis_env, var, err, d_var, d_err)
      TYPE(almo_scf_diis_type), INTENT(INOUT)            :: diis_env
      TYPE(dbcsr_type), INTENT(IN), OPTIONAL             :: var, err
      TYPE(domain_submatrix_type), DIMENSION(:), &
         INTENT(IN), OPTIONAL                            :: d_var, d_err

      CHARACTER(len=*), PARAMETER :: routineN = 'almo_scf_diis_push'

      INTEGER                                            :: handle, idomain, in_point, irow, &
                                                            ndomains, old_buffer_length
      REAL(KIND=dp)                                      :: trace0
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: m_b_tmp

      CALL timeset(routineN, handle)

      IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
         IF (.NOT. (PRESENT(var) .AND. PRESENT(err))) THEN
            CPABORT("provide DBCSR matrices")
         END IF
      ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
         IF (.NOT. (PRESENT(d_var) .AND. PRESENT(d_err))) THEN
            CPABORT("provide domain submatrices")
         END IF
      ELSE
         CPABORT("illegal DIIS ENV type")
      END IF

      in_point = diis_env%in_point

      ! store a var-error pair
      IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
         CALL dbcsr_copy(diis_env%m_var(in_point), var)
         CALL dbcsr_copy(diis_env%m_err(in_point), err)
      ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
         CALL copy_submatrices(d_var, diis_env%d_var(in_point, :), copy_data=.TRUE.)
         CALL copy_submatrices(d_err, diis_env%d_err(in_point, :), copy_data=.TRUE.)
      END IF

      ! update the buffer length
      old_buffer_length = diis_env%buffer_length
      diis_env%buffer_length = diis_env%buffer_length + 1
      IF (diis_env%buffer_length .GT. diis_env%max_buffer_length) &
         diis_env%buffer_length = diis_env%max_buffer_length

      !!!! resize B matrix
      !!!IF (old_buffer_length.lt.diis_env%buffer_length) THEN
      !!!   ALLOCATE(m_b_tmp(diis_env%buffer_length+1,diis_env%buffer_length+1))
      !!!   m_b_tmp(1:diis_env%buffer_length,1:diis_env%buffer_length)=&
      !!!      diis_env%m_b(:,:)
      !!!   DEALLOCATE(diis_env%m_b)
      !!!   ALLOCATE(diis_env%m_b(diis_env%buffer_length+1,&
      !!!      diis_env%buffer_length+1))
      !!!   diis_env%m_b(:,:)=m_b_tmp(:,:)
      !!!   DEALLOCATE(m_b_tmp)
      !!!ENDIF
      !!!! update B matrix elements
      !!!diis_env%m_b(1,in_point+1)=-1.0_dp
      !!!diis_env%m_b(in_point+1,1)=-1.0_dp
      !!!DO irow=1,diis_env%buffer_length
      !!!   trace0=almo_scf_diis_error_overlap(diis_env,&
      !!!      A=diis_env%m_err(irow),B=diis_env%m_err(in_point))
      !!!
      !!!   diis_env%m_b(irow+1,in_point+1)=trace0
      !!!   diis_env%m_b(in_point+1,irow+1)=trace0
      !!!ENDDO

      ! resize B matrix and update its elements
      ndomains = SIZE(diis_env%m_b)
      IF (old_buffer_length .LT. diis_env%buffer_length) THEN
         ALLOCATE (m_b_tmp(diis_env%buffer_length + 1, diis_env%buffer_length + 1))
         DO idomain = 1, ndomains
            IF (diis_env%m_b(idomain)%domain .GT. 0) THEN
               m_b_tmp(:, :) = 0.0_dp
               m_b_tmp(1:diis_env%buffer_length, 1:diis_env%buffer_length) = &
                  diis_env%m_b(idomain)%mdata(:, :)
               DEALLOCATE (diis_env%m_b(idomain)%mdata)
               ALLOCATE (diis_env%m_b(idomain)%mdata(diis_env%buffer_length + 1, &
                                                     diis_env%buffer_length + 1))
               diis_env%m_b(idomain)%mdata(:, :) = m_b_tmp(:, :)
            END IF
         END DO
         DEALLOCATE (m_b_tmp)
      END IF
      DO idomain = 1, ndomains
         IF (diis_env%m_b(idomain)%domain .GT. 0) THEN
            diis_env%m_b(idomain)%mdata(1, in_point + 1) = -1.0_dp
            diis_env%m_b(idomain)%mdata(in_point + 1, 1) = -1.0_dp
            DO irow = 1, diis_env%buffer_length
               IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
                  trace0 = almo_scf_diis_error_overlap(diis_env, &
                                                       A=diis_env%m_err(irow), B=diis_env%m_err(in_point))
               ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
                  trace0 = almo_scf_diis_error_overlap(diis_env, &
                                                       d_A=diis_env%d_err(irow, idomain), &
                                                       d_B=diis_env%d_err(in_point, idomain))
               END IF
               diis_env%m_b(idomain)%mdata(irow + 1, in_point + 1) = trace0
               diis_env%m_b(idomain)%mdata(in_point + 1, irow + 1) = trace0
            END DO ! loop over prev errors
         END IF
      END DO ! loop over domains

      ! update the insertion point for the next "PUSH"
      diis_env%in_point = diis_env%in_point + 1
      IF (diis_env%in_point .GT. diis_env%max_buffer_length) diis_env%in_point = 1

      CALL timestop(handle)

   END SUBROUTINE almo_scf_diis_push

! **************************************************************************************************
!> \brief extrapolates the variable using the saved history
!> \param diis_env ...
!> \param extr_var ...
!> \param d_extr_var ...
!> \par History
!>       2011.12 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE almo_scf_diis_extrapolate(diis_env, extr_var, d_extr_var)
      TYPE(almo_scf_diis_type), INTENT(INOUT)            :: diis_env
      TYPE(dbcsr_type), INTENT(INOUT), OPTIONAL          :: extr_var
      TYPE(domain_submatrix_type), DIMENSION(:), &
         INTENT(INOUT), OPTIONAL                         :: d_extr_var

      CHARACTER(len=*), PARAMETER :: routineN = 'almo_scf_diis_extrapolate'

      INTEGER                                            :: handle, idomain, im, INFO, LWORK, &
                                                            ndomains, unit_nr
      REAL(KIND=dp)                                      :: checksum
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: coeff, eigenvalues, tmp1, WORK
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: m_b_copy
      TYPE(cp_logger_type), POINTER                      :: logger

      CALL timeset(routineN, handle)

      ! get a useful output_unit
      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         unit_nr = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         unit_nr = -1
      END IF

      IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
         IF (.NOT. PRESENT(extr_var)) THEN
            CPABORT("provide DBCSR matrix")
         END IF
      ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
         IF (.NOT. PRESENT(d_extr_var)) THEN
            CPABORT("provide domain submatrices")
         END IF
      ELSE
         CPABORT("illegal DIIS ENV type")
      END IF

      ! Prepare data
      ALLOCATE (eigenvalues(diis_env%buffer_length + 1))
      ALLOCATE (m_b_copy(diis_env%buffer_length + 1, diis_env%buffer_length + 1))

      ndomains = SIZE(diis_env%m_b)

      DO idomain = 1, ndomains

         IF (diis_env%m_b(idomain)%domain .GT. 0) THEN

            m_b_copy(:, :) = diis_env%m_b(idomain)%mdata(:, :)

            ! Query the optimal workspace for dsyev
            LWORK = -1
            ALLOCATE (WORK(MAX(1, LWORK)))
            CALL DSYEV('V', 'L', diis_env%buffer_length + 1, m_b_copy, &
                       diis_env%buffer_length + 1, eigenvalues, WORK, LWORK, INFO)
            LWORK = INT(WORK(1))
            DEALLOCATE (WORK)

            ! Allocate the workspace and solve the eigenproblem
            ALLOCATE (WORK(MAX(1, LWORK)))
            CALL DSYEV('V', 'L', diis_env%buffer_length + 1, m_b_copy, &
                       diis_env%buffer_length + 1, eigenvalues, WORK, LWORK, INFO)
            IF (INFO .NE. 0) THEN
               CPABORT("DSYEV failed")
            END IF
            DEALLOCATE (WORK)

            ! use the eigensystem to invert (implicitly) B matrix
            ! and compute the extrapolation coefficients
            !! ALLOCATE(tmp1(diis_env%buffer_length+1,1))
            !! ALLOCATE(coeff(diis_env%buffer_length+1,1))
            !! tmp1(:,1)=-1.0_dp*m_b_copy(1,:)/eigenvalues(:)
            !! coeff=MATMUL(m_b_copy,tmp1)
            !! DEALLOCATE(tmp1)
            ALLOCATE (tmp1(diis_env%buffer_length + 1))
            ALLOCATE (coeff(diis_env%buffer_length + 1))
            tmp1(:) = -1.0_dp*m_b_copy(1, :)/eigenvalues(:)
            coeff(:) = MATMUL(m_b_copy, tmp1)
            DEALLOCATE (tmp1)

            !IF (unit_nr.gt.0) THEN
            !   DO im=1,diis_env%buffer_length+1
            !      WRITE(unit_nr,*) diis_env%m_b(idomain)%mdata(im,:)
            !   ENDDO
            !   WRITE (unit_nr,*) coeff(:,1)
            !ENDIF

            ! extrapolate the variable
            checksum = 0.0_dp
            IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
               CALL dbcsr_set(extr_var, 0.0_dp)
               DO im = 1, diis_env%buffer_length
                  CALL dbcsr_add(extr_var, diis_env%m_var(im), &
                                 1.0_dp, coeff(im + 1))
                  checksum = checksum + coeff(im + 1)
               END DO
            ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
               CALL copy_submatrices(diis_env%d_var(1, idomain), &
                                     d_extr_var(idomain), &
                                     copy_data=.FALSE.)
               CALL set_submatrices(d_extr_var(idomain), 0.0_dp)
               DO im = 1, diis_env%buffer_length
                  CALL add_submatrices(1.0_dp, d_extr_var(idomain), &
                                       coeff(im + 1), diis_env%d_var(im, idomain), &
                                       'N')
                  checksum = checksum + coeff(im + 1)
               END DO
            END IF
            !WRITE(*,*) checksum

            DEALLOCATE (coeff)

         END IF ! domain is local to this mpi node

      END DO ! loop over domains

      DEALLOCATE (eigenvalues)
      DEALLOCATE (m_b_copy)

      CALL timestop(handle)

   END SUBROUTINE almo_scf_diis_extrapolate

! **************************************************************************************************
!> \brief computes elements of b-matrix
!> \param diis_env ...
!> \param A ...
!> \param B ...
!> \param d_A ...
!> \param d_B ...
!> \return ...
!> \par History
!>       2013.02 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   FUNCTION almo_scf_diis_error_overlap(diis_env, A, B, d_A, d_B)

      TYPE(almo_scf_diis_type), INTENT(INOUT)            :: diis_env
      TYPE(dbcsr_type), INTENT(INOUT), OPTIONAL          :: A, B
      TYPE(domain_submatrix_type), INTENT(INOUT), &
         OPTIONAL                                        :: d_A, d_B
      REAL(KIND=dp)                                      :: almo_scf_diis_error_overlap

      CHARACTER(len=*), PARAMETER :: routineN = 'almo_scf_diis_error_overlap'

      INTEGER                                            :: handle
      REAL(KIND=dp)                                      :: trace

      CALL timeset(routineN, handle)

      IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
         IF (.NOT. (PRESENT(A) .AND. PRESENT(B))) THEN
            CPABORT("provide DBCSR matrices")
         END IF
      ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
         IF (.NOT. (PRESENT(d_A) .AND. PRESENT(d_B))) THEN
            CPABORT("provide domain submatrices")
         END IF
      ELSE
         CPABORT("illegal DIIS ENV type")
      END IF

      SELECT CASE (diis_env%error_type)
      CASE (diis_error_orthogonal)
         IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
            CALL dbcsr_dot(A, B, trace)
         ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
            CPASSERT(SIZE(d_A%mdata, 1) .EQ. SIZE(d_B%mdata, 1))
            CPASSERT(SIZE(d_A%mdata, 2) .EQ. SIZE(d_B%mdata, 2))
            CPASSERT(d_A%domain .EQ. d_B%domain)
            CPASSERT(d_A%domain .GT. 0)
            CPASSERT(d_B%domain .GT. 0)
            trace = SUM(d_A%mdata(:, :)*d_B%mdata(:, :))
         END IF
      CASE DEFAULT
         CPABORT("Vector type is unknown")
      END SELECT

      almo_scf_diis_error_overlap = trace

      CALL timestop(handle)

   END FUNCTION almo_scf_diis_error_overlap

! **************************************************************************************************
!> \brief destroys the diis structure
!> \param diis_env ...
!> \par History
!>       2011.12 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE almo_scf_diis_release(diis_env)
      TYPE(almo_scf_diis_type), INTENT(INOUT)            :: diis_env

      CHARACTER(len=*), PARAMETER :: routineN = 'almo_scf_diis_release'

      INTEGER                                            :: handle, im

      CALL timeset(routineN, handle)

      ! release matrices
      DO im = 1, diis_env%max_buffer_length
         IF (diis_env%diis_env_type .EQ. diis_env_dbcsr) THEN
            CALL dbcsr_release(diis_env%m_err(im))
            CALL dbcsr_release(diis_env%m_var(im))
         ELSE IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
            CALL release_submatrices(diis_env%d_var(im, :))
            CALL release_submatrices(diis_env%d_err(im, :))
         END IF
      END DO

      IF (diis_env%diis_env_type .EQ. diis_env_domain) THEN
         CALL release_submatrices(diis_env%m_b(:))
      END IF

      IF (ALLOCATED(diis_env%m_b)) DEALLOCATE (diis_env%m_b)
      IF (ALLOCATED(diis_env%m_err)) DEALLOCATE (diis_env%m_err)
      IF (ALLOCATED(diis_env%m_var)) DEALLOCATE (diis_env%m_var)
      IF (ALLOCATED(diis_env%d_err)) DEALLOCATE (diis_env%d_err)
      IF (ALLOCATED(diis_env%d_var)) DEALLOCATE (diis_env%d_var)

      CALL timestop(handle)

   END SUBROUTINE almo_scf_diis_release

END MODULE almo_scf_diis_types

