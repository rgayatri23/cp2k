!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief represent the structure of a full matrix
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
MODULE cp_fm_struct
   USE cp_blacs_env,                    ONLY: cp_blacs_env_release,&
                                              cp_blacs_env_retain,&
                                              cp_blacs_env_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type,&
                                              cp_to_string
   USE cp_para_env,                     ONLY: cp_para_env_release,&
                                              cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE kinds,                           ONLY: dp
   USE machine,                         ONLY: m_flush
   USE message_passing,                 ONLY: mp_sum
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_fm_struct'

! the default blacs block sizes
! consider using #ifdefs to give them the optimal values
! these can be changed using scf_control
! *** these are used by default
   INTEGER, PRIVATE :: optimal_blacs_col_block_size = 32
   INTEGER, PRIVATE :: optimal_blacs_row_block_size = 32
   LOGICAL, PRIVATE :: force_block_size = .FALSE.

   PUBLIC :: cp_fm_struct_type, cp_fm_struct_p_type
   PUBLIC :: cp_fm_struct_create, cp_fm_struct_retain, cp_fm_struct_release, &
             cp_fm_struct_equivalent, &
             cp_fm_struct_get, cp_fm_struct_double, cp_fm_struct_config, &
             cp_fm_struct_get_nrow_block, cp_fm_struct_get_ncol_block, &
             cp_fm_struct_write_info

! **************************************************************************************************
!> \brief keeps the information about the structure of a full matrix
!> \param para_env the parallel environment of the matrices with this structure
!> \param context the blacs context (parallel environment for scalapack),
!>        should be compatible with para_env
!> \param descriptor the scalapack descriptor of the matrices, when using
!>        scalapack (ncol_block=descriptor(6), ncol_global=descriptor(4),
!>        nrow_block=descriptor(5), nrow_global=descriptor(3))
!> \param ncol_block number of columns of a scalapack block
!> \param nrow_block number of rows of a scalapack block
!> \param nrow_global number of rows of the matrix
!> \param ncol_global number of rows
!> \param first_p_pos position of the first processor (for scalapack)
!> \param row_indices real (global) indices of the rows (defined only for
!>        the local rows really used)
!> \param col_indices real (global) indices of the cols (defined only for
!>        the local cols really used)
!> \param nrow_locals nrow_locals(i) number of local rows of the matrix really
!>        used on the processors with context%mepos(1)==i
!> \param ncol_locals ncol_locals(i) number of local rows of the matrix really
!>        used on the processors with context%mepos(2)==i
!> \param ref_count reference count (see doc/ReferenceCounting.html)
!> \param local_leading_dimension leading dimension of the data that is
!>        stored on this processor
!>
!>      readonly attributes:
!> \param nrow_local number of local rows really used on the actual processor
!> \param ncol_local number of local cols really used on the actual processor
!> \note
!>      use cp_fm_struct_get to extract information from this structure
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   TYPE cp_fm_struct_type
      TYPE(cp_para_env_type), POINTER :: para_env
      TYPE(cp_blacs_env_type), POINTER :: context
      INTEGER, DIMENSION(9) :: descriptor
      INTEGER :: nrow_block, ncol_block, nrow_global, ncol_global
      INTEGER, DIMENSION(2) :: first_p_pos
      INTEGER, DIMENSION(:), POINTER :: row_indices, col_indices, &
                                        nrow_locals, ncol_locals
      INTEGER :: ref_count, local_leading_dimension
   END TYPE cp_fm_struct_type
! **************************************************************************************************
   TYPE cp_fm_struct_p_type
      TYPE(cp_fm_struct_type), POINTER :: struct
   END TYPE cp_fm_struct_p_type

CONTAINS

! **************************************************************************************************
!> \brief allocates and initializes a full matrix structure
!> \param fmstruct the pointer that will point to the new structure
!> \param para_env the parallel environment
!> \param context the blacs context of this matrix
!> \param nrow_global the number of row of the full matrix
!> \param ncol_global the number of columns of the full matrix
!> \param nrow_block the number of rows of a block of the matrix,
!>        omit or set to -1 to use the built-in defaults
!> \param ncol_block the number of columns of a block of the matrix,
!>        omit or set to -1 to use the built-in defaults
!> \param descriptor the scalapack descriptor of the matrix (if not given
!>        a new one is allocated
!> \param first_p_pos ...
!> \param local_leading_dimension the leading dimension of the locally stored
!>        data block
!> \param template_fmstruct a matrix structure where to take the default values
!> \param square_blocks ...
!> \param force_block ...
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_create(fmstruct, para_env, context, nrow_global, &
                                  ncol_global, nrow_block, ncol_block, descriptor, first_p_pos, &
                                  local_leading_dimension, template_fmstruct, square_blocks, force_block)

      TYPE(cp_fm_struct_type), POINTER             :: fmstruct
      TYPE(cp_para_env_type), POINTER, OPTIONAL    :: para_env
      INTEGER, INTENT(in), OPTIONAL                :: nrow_global, ncol_global
      INTEGER, INTENT(in), OPTIONAL                :: nrow_block, ncol_block
      INTEGER, INTENT(in), OPTIONAL                :: local_leading_dimension
      TYPE(cp_blacs_env_type), POINTER, OPTIONAL   :: context
      INTEGER, DIMENSION(9), INTENT(in), OPTIONAL  :: descriptor
      INTEGER, OPTIONAL, DIMENSION(2)               :: first_p_pos
      TYPE(cp_fm_struct_type), POINTER, OPTIONAL   :: template_fmstruct
      LOGICAL, OPTIONAL, INTENT(in)                :: square_blocks
      LOGICAL, OPTIONAL, INTENT(in)                :: force_block

      INTEGER                                      :: dumblock
#if defined(__SCALAPACK)
      INTEGER                                      :: iunit, stat
      INTEGER, EXTERNAL                            :: numroc
      TYPE(cp_logger_type), POINTER                :: logger
#endif

      LOGICAL :: my_square_blocks, my_force_block

#if defined(__parallel) && ! defined(__SCALAPACK)
      CPABORT("full matrices need scalapack for parallel runs ")
#endif

      ALLOCATE (fmstruct)

      fmstruct%nrow_block = optimal_blacs_row_block_size
      fmstruct%ncol_block = optimal_blacs_col_block_size

      IF (.NOT. PRESENT(template_fmstruct)) THEN
         CPASSERT(PRESENT(context))
         CPASSERT(PRESENT(nrow_global))
         CPASSERT(PRESENT(ncol_global))
         fmstruct%local_leading_dimension = 1
      ELSE
         fmstruct%context => template_fmstruct%context
         fmstruct%para_env => template_fmstruct%para_env
         fmstruct%descriptor = template_fmstruct%descriptor
         fmstruct%nrow_block = template_fmstruct%nrow_block
         fmstruct%nrow_global = template_fmstruct%nrow_global
         fmstruct%ncol_block = template_fmstruct%ncol_block
         fmstruct%ncol_global = template_fmstruct%ncol_global
         fmstruct%first_p_pos = template_fmstruct%first_p_pos
         fmstruct%local_leading_dimension = &
            template_fmstruct%local_leading_dimension
      END IF

      my_force_block = force_block_size
      IF (PRESENT(force_block)) my_force_block = force_block

      IF (PRESENT(context)) THEN
         fmstruct%context => context
         fmstruct%para_env => context%para_env
      END IF
      IF (PRESENT(para_env)) fmstruct%para_env => para_env
      CALL cp_blacs_env_retain(fmstruct%context)
      CALL cp_para_env_retain(fmstruct%para_env)

      IF (PRESENT(nrow_global)) THEN
         fmstruct%nrow_global = nrow_global
         fmstruct%local_leading_dimension = 1
      END IF
      IF (PRESENT(ncol_global)) THEN
         fmstruct%ncol_global = ncol_global
      END IF

      ! try to avoid small left-over blocks (anyway naive)
      IF (PRESENT(nrow_block)) THEN
         IF (nrow_block > 0) & ! allows setting the number of blocks to -1 to explicitly set to auto
            fmstruct%nrow_block = nrow_block
      END IF
      IF (.NOT. my_force_block) THEN
         dumblock = CEILING(REAL(fmstruct%nrow_global, KIND=dp)/ &
                            REAL(fmstruct%context%num_pe(1), KIND=dp))
         fmstruct%nrow_block = MAX(1, MIN(fmstruct%nrow_block, dumblock))
      END IF
      IF (PRESENT(ncol_block)) THEN
         IF (ncol_block > 0) & ! allows setting the number of blocks to -1 to explicitly set to auto
            fmstruct%ncol_block = ncol_block
      END IF
      IF (.NOT. my_force_block) THEN
         dumblock = CEILING(REAL(fmstruct%ncol_global, KIND=dp)/ &
                            REAL(fmstruct%context%num_pe(2), KIND=dp))
         fmstruct%ncol_block = MAX(1, MIN(fmstruct%ncol_block, dumblock))
      END IF

      ! square matrix -> square blocks (otherwise some op fail)
      my_square_blocks = fmstruct%nrow_global == fmstruct%ncol_global
      IF (PRESENT(square_blocks)) my_square_blocks = square_blocks
      IF (my_square_blocks) THEN
         fmstruct%nrow_block = MIN(fmstruct%nrow_block, fmstruct%ncol_block)
         fmstruct%ncol_block = fmstruct%nrow_block
      END IF

      ALLOCATE (fmstruct%nrow_locals(0:(fmstruct%context%num_pe(1) - 1)), &
                fmstruct%ncol_locals(0:(fmstruct%context%num_pe(2) - 1)))
      IF (.NOT. PRESENT(template_fmstruct)) &
         fmstruct%first_p_pos = (/0, 0/)
      IF (PRESENT(first_p_pos)) fmstruct%first_p_pos = first_p_pos

      fmstruct%nrow_locals = 0
      fmstruct%ncol_locals = 0
#if defined(__SCALAPACK)
      fmstruct%nrow_locals(fmstruct%context%mepos(1)) = &
         numroc(fmstruct%nrow_global, fmstruct%nrow_block, &
                fmstruct%context%mepos(1), fmstruct%first_p_pos(1), &
                fmstruct%context%num_pe(1))
      fmstruct%ncol_locals(fmstruct%context%mepos(2)) = &
         numroc(fmstruct%ncol_global, fmstruct%ncol_block, &
                fmstruct%context%mepos(2), fmstruct%first_p_pos(2), &
                fmstruct%context%num_pe(2))
      CALL mp_sum(fmstruct%nrow_locals, fmstruct%para_env%group)
      CALL mp_sum(fmstruct%ncol_locals, fmstruct%para_env%group)
      fmstruct%nrow_locals(:) = fmstruct%nrow_locals(:)/fmstruct%context%num_pe(2)
      fmstruct%ncol_locals(:) = fmstruct%ncol_locals(:)/fmstruct%context%num_pe(1)

      IF (SUM(fmstruct%ncol_locals) .NE. fmstruct%ncol_global .OR. &
          SUM(fmstruct%nrow_locals) .NE. fmstruct%nrow_global) THEN
         ! try to collect some output if this is going to happen again
         ! this seems to trigger on blanc, but should really never happen
         logger => cp_get_default_logger()
         iunit = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
         WRITE (iunit, *) "mepos", fmstruct%context%mepos(1:2), "numpe", fmstruct%context%num_pe(1:2)
         WRITE (iunit, *) "ncol_global", fmstruct%ncol_global
         WRITE (iunit, *) "nrow_global", fmstruct%nrow_global
         WRITE (iunit, *) "ncol_locals", fmstruct%ncol_locals
         WRITE (iunit, *) "nrow_locals", fmstruct%nrow_locals
         CALL m_flush(iunit)
      END IF

      IF (SUM(fmstruct%ncol_locals) .NE. fmstruct%ncol_global) &
         CPABORT("sum of local cols not equal global cols")
      IF (SUM(fmstruct%nrow_locals) .NE. fmstruct%nrow_global) &
         CPABORT("sum of local row not equal global rows")
#else
      ! block = full matrix
      fmstruct%nrow_block = fmstruct%nrow_global
      fmstruct%ncol_block = fmstruct%ncol_global
      fmstruct%nrow_locals(fmstruct%context%mepos(1)) = fmstruct%nrow_global
      fmstruct%ncol_locals(fmstruct%context%mepos(2)) = fmstruct%ncol_global
#endif

      fmstruct%local_leading_dimension = MAX(fmstruct%local_leading_dimension, &
                                             fmstruct%nrow_locals(fmstruct%context%mepos(1)))
      IF (PRESENT(local_leading_dimension)) THEN
         IF (MAX(1, fmstruct%nrow_locals(fmstruct%context%mepos(1))) > local_leading_dimension) &
            CALL cp_abort(__LOCATION__, "local_leading_dimension too small ("// &
                          cp_to_string(local_leading_dimension)//"<"// &
                          cp_to_string(fmstruct%local_leading_dimension)//")")
         fmstruct%local_leading_dimension = local_leading_dimension
      END IF

      NULLIFY (fmstruct%row_indices, fmstruct%col_indices)
      fmstruct%ref_count = 1

      IF (PRESENT(descriptor)) THEN
         fmstruct%descriptor = descriptor
      ELSE
         fmstruct%descriptor = 0
#if defined(__SCALAPACK)
         ! local leading dimension needs to be at least 1
         CALL descinit(fmstruct%descriptor, fmstruct%nrow_global, &
                       fmstruct%ncol_global, fmstruct%nrow_block, &
                       fmstruct%ncol_block, fmstruct%first_p_pos(1), &
                       fmstruct%first_p_pos(2), fmstruct%context%group, &
                       fmstruct%local_leading_dimension, stat)
         CPASSERT(stat == 0)
#endif
      END IF
   END SUBROUTINE cp_fm_struct_create

! **************************************************************************************************
!> \brief retains a full matrix structure
!> \param fmstruct the structure to retain
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_retain(fmstruct)
      TYPE(cp_fm_struct_type), POINTER                   :: fmstruct

      CPASSERT(ASSOCIATED(fmstruct))
      CPASSERT(fmstruct%ref_count > 0)
      fmstruct%ref_count = fmstruct%ref_count + 1
   END SUBROUTINE cp_fm_struct_retain

! **************************************************************************************************
!> \brief releases a full matrix structure
!> \param fmstruct the structure to release
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_release(fmstruct)
      TYPE(cp_fm_struct_type), POINTER                   :: fmstruct

      IF (ASSOCIATED(fmstruct)) THEN
         CPASSERT(fmstruct%ref_count > 0)
         fmstruct%ref_count = fmstruct%ref_count - 1
         IF (fmstruct%ref_count < 1) THEN
            CALL cp_blacs_env_release(fmstruct%context)
            CALL cp_para_env_release(fmstruct%para_env)
            IF (ASSOCIATED(fmstruct%row_indices)) THEN
               DEALLOCATE (fmstruct%row_indices)
            END IF
            IF (ASSOCIATED(fmstruct%col_indices)) THEN
               DEALLOCATE (fmstruct%col_indices)
            END IF
            IF (ASSOCIATED(fmstruct%nrow_locals)) THEN
               DEALLOCATE (fmstruct%nrow_locals)
            END IF
            IF (ASSOCIATED(fmstruct%ncol_locals)) THEN
               DEALLOCATE (fmstruct%ncol_locals)
            END IF
            DEALLOCATE (fmstruct)
         END IF
      END IF
      NULLIFY (fmstruct)
   END SUBROUTINE cp_fm_struct_release

! **************************************************************************************************
!> \brief returns true if the two matrix structures are equivalent, false
!>      otherwise.
!> \param fmstruct1 one of the full matrix structures to compare
!> \param fmstruct2 the second of the full matrix structures to compare
!> \return ...
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   FUNCTION cp_fm_struct_equivalent(fmstruct1, fmstruct2) RESULT(res)
      TYPE(cp_fm_struct_type), POINTER                   :: fmstruct1, fmstruct2
      LOGICAL                                            :: res

      INTEGER                                            :: i

      CPASSERT(ASSOCIATED(fmstruct1))
      CPASSERT(ASSOCIATED(fmstruct2))
      CPASSERT(fmstruct1%ref_count > 0)
      CPASSERT(fmstruct2%ref_count > 0)
      IF (ASSOCIATED(fmstruct1, fmstruct2)) THEN
         res = .TRUE.
      ELSE
         res = (fmstruct1%context%group == fmstruct2%context%group) .AND. &
               (fmstruct1%nrow_global == fmstruct2%nrow_global) .AND. &
               (fmstruct1%ncol_global == fmstruct2%ncol_global) .AND. &
               (fmstruct1%local_leading_dimension == &
                fmstruct2%local_leading_dimension)
         DO i = 1, 9
            res = res .AND. (fmstruct1%descriptor(i) == fmstruct1%descriptor(i))
         END DO
      END IF
   END FUNCTION cp_fm_struct_equivalent

! **************************************************************************************************
!> \brief returns the values of various attributes of the matrix structure
!> \param fmstruct the structure you want info about
!> \param para_env ...
!> \param context ...
!> \param descriptor ...
!> \param ncol_block ...
!> \param nrow_block ...
!> \param nrow_global ...
!> \param ncol_global ...
!> \param first_p_pos ...
!> \param row_indices ...
!> \param col_indices ...
!> \param nrow_local ...
!> \param ncol_local ...
!> \param nrow_locals ...
!> \param ncol_locals ...
!> \param local_leading_dimension ...
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_get(fmstruct, para_env, context, &
                               descriptor, ncol_block, nrow_block, nrow_global, &
                               ncol_global, first_p_pos, row_indices, &
                               col_indices, nrow_local, ncol_local, nrow_locals, ncol_locals, &
                               local_leading_dimension)
      TYPE(cp_fm_struct_type), INTENT(INOUT) :: fmstruct
      TYPE(cp_para_env_type), POINTER, OPTIONAL :: para_env
      TYPE(cp_blacs_env_type), POINTER, OPTIONAL :: context
      INTEGER, DIMENSION(9), INTENT(OUT), OPTIONAL :: descriptor
      INTEGER, INTENT(out), OPTIONAL :: ncol_block, nrow_block, nrow_global, &
                                        ncol_global, nrow_local, ncol_local, &
                                        local_leading_dimension
      INTEGER, DIMENSION(2), INTENT(out), OPTIONAL :: first_p_pos
      INTEGER, DIMENSION(:), POINTER, OPTIONAL :: row_indices, col_indices, &
                                                  nrow_locals, ncol_locals

      INTEGER i, nprow, npcol, myprow, mypcol
#if defined(__SCALAPACK)
      INTEGER, EXTERNAL :: indxl2g
#endif

      IF (PRESENT(para_env)) para_env => fmstruct%para_env
      IF (PRESENT(context)) context => fmstruct%context
      IF (PRESENT(descriptor)) descriptor = fmstruct%descriptor
      IF (PRESENT(ncol_block)) ncol_block = fmstruct%ncol_block
      IF (PRESENT(nrow_block)) nrow_block = fmstruct%nrow_block
      IF (PRESENT(nrow_global)) nrow_global = fmstruct%nrow_global
      IF (PRESENT(ncol_global)) ncol_global = fmstruct%ncol_global
      IF (PRESENT(first_p_pos)) first_p_pos = fmstruct%first_p_pos
      IF (PRESENT(nrow_locals)) nrow_locals => fmstruct%nrow_locals
      IF (PRESENT(ncol_locals)) ncol_locals => fmstruct%ncol_locals
      IF (PRESENT(local_leading_dimension)) local_leading_dimension = &
         fmstruct%local_leading_dimension

      myprow = fmstruct%context%mepos(1)
      mypcol = fmstruct%context%mepos(2)
      nprow = fmstruct%context%num_pe(1)
      npcol = fmstruct%context%num_pe(2)

      IF (PRESENT(nrow_local)) nrow_local = fmstruct%nrow_locals(myprow)
      IF (PRESENT(ncol_local)) ncol_local = fmstruct%ncol_locals(mypcol)

      IF (PRESENT(row_indices)) THEN
         row_indices => fmstruct%row_indices
         IF (.NOT. ASSOCIATED(row_indices)) THEN
            ! the max should go away
            ALLOCATE (fmstruct%row_indices(MAX(fmstruct%nrow_locals(myprow), 1)))
            row_indices => fmstruct%row_indices
#ifdef __SCALAPACK
            DO i = 1, SIZE(row_indices)
               row_indices(i) = &
                  indxl2g(i, fmstruct%nrow_block, myprow, fmstruct%first_p_pos(1), nprow)
            END DO
#else
            DO i = 1, SIZE(row_indices)
               row_indices(i) = i
            END DO
#endif
         END IF
      END IF

      IF (PRESENT(col_indices)) THEN
         col_indices => fmstruct%col_indices
         IF (.NOT. ASSOCIATED(col_indices)) THEN
            ALLOCATE (fmstruct%col_indices(MAX(fmstruct%ncol_locals(mypcol), 1)))
            col_indices => fmstruct%col_indices
#ifdef __SCALAPACK
            DO i = 1, SIZE(col_indices)
               col_indices(i) = &
                  indxl2g(i, fmstruct%ncol_block, mypcol, fmstruct%first_p_pos(2), npcol)
            END DO
#else
            DO i = 1, SIZE(col_indices)
               col_indices(i) = i
            END DO
#endif
         END IF

      END IF
   END SUBROUTINE cp_fm_struct_get

! **************************************************************************************************
!> \brief Write nicely formatted info about the FM struct to the given I/O unit
!> \param fmstruct a cp_fm_struct_type instance
!> \param io_unit the I/O unit to use for writing
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_write_info(fmstruct, io_unit)
      TYPE(cp_fm_struct_type), INTENT(IN), POINTER       :: fmstruct
      INTEGER, INTENT(IN)                                :: io_unit

      INTEGER, PARAMETER                                 :: oblock_size = 8

      CHARACTER(len=30)                                  :: fm
      INTEGER                                            :: oblock

      WRITE (fm, "(A,I2,A)") "(A,I5,A,I5,A,", oblock_size, "I6)"

      WRITE (io_unit, '(A,I12)') "CP_FM_STRUCT | No. of matrix columns:   ", fmstruct%ncol_global
      WRITE (io_unit, '(A,I12)') "CP_FM_STRUCT | No. of matrix rows:      ", fmstruct%nrow_global
      WRITE (io_unit, '(A,I12)') "CP_FM_STRUCT | No. of block columns:    ", fmstruct%ncol_block
      WRITE (io_unit, '(A,I12)') "CP_FM_STRUCT | No. of block rows:       ", fmstruct%nrow_block

      WRITE (io_unit, '(A)') "CP_FM_STRUCT | Number of local columns: "
      DO oblock = 0, (SIZE(fmstruct%ncol_locals) - 1)/oblock_size
         WRITE (io_unit, fm) "CP_FM_STRUCT | CPUs ", &
            oblock*oblock_size, "..", (oblock + 1)*oblock_size - 1, ": ", &
            fmstruct%ncol_locals(oblock*oblock_size:MIN(SIZE(fmstruct%ncol_locals), (oblock + 1)*oblock_size) - 1)
      END DO

      WRITE (io_unit, '(A)') "CP_FM_STRUCT | Number of local rows:    "
      DO oblock = 0, (SIZE(fmstruct%nrow_locals) - 1)/oblock_size
         WRITE (io_unit, fm) "CP_FM_STRUCT | CPUs ", &
            oblock*oblock_size, "..", (oblock + 1)*oblock_size - 1, ": ", &
            fmstruct%nrow_locals(oblock*oblock_size:MIN(SIZE(fmstruct%nrow_locals), (oblock + 1)*oblock_size) - 1)
      END DO
   END SUBROUTINE cp_fm_struct_write_info

! **************************************************************************************************
!> \brief creates a struct with twice the number of blocks on each core.
!>        If matrix A has to be multiplied with B anc C, a
!>        significant speedup of pdgemm can be acchieved by joining the matrices
!>        in a new one with this structure (see arnoldi in rt_matrix_exp)
!> \param fmstruct the struct to create
!> \param struct struct of either A or B
!> \param context ...
!> \param col in which direction the matrix should be enlarged
!> \param row in which direction the matrix should be enlarged
!> \par History
!>      06.2009 created [fschiff]
!> \author Florian Schiffmann
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_double(fmstruct, struct, context, col, row)
      TYPE(cp_fm_struct_type), POINTER                   :: fmstruct, struct
      TYPE(cp_blacs_env_type), POINTER                   :: context
      LOGICAL, INTENT(in)                                :: col, row

      INTEGER :: n_doubled_items_in_partially_filled_block, ncol_block, ncol_global, newdim_col, &
         newdim_row, nfilled_blocks, nfilled_blocks_remain, nprocs_col, nprocs_row, nrow_block, &
         nrow_global
      TYPE(cp_para_env_type), POINTER                    :: para_env

      CALL cp_fm_struct_get(struct, nrow_global=nrow_global, &
                            ncol_global=ncol_global, nrow_block=nrow_block, &
                            ncol_block=ncol_block)
      newdim_row = nrow_global
      newdim_col = ncol_global
      nprocs_row = context%num_pe(1)
      nprocs_col = context%num_pe(2)
      para_env => struct%para_env

      IF (col) THEN
         IF (ncol_global == 0) THEN
            newdim_col = 0
         ELSE
            ! ncol_block            nfilled_blocks_remain * ncol_block
            !     |<--->|           |<--->|
            !     |-----|-----|-----|-----|---|
            !     |  0  |  1  |  2  |  0  | 1 | <- context%mepos(2)
            !     |-----|-----|-----|-----|---|
            !     |<--- nfilled_blocks -->|<->  -- items (columns) in partially filled blocks
            !     |     * ncol_block      |
            n_doubled_items_in_partially_filled_block = 2*MOD(ncol_global, ncol_block)
            nfilled_blocks = ncol_global/ncol_block
            nfilled_blocks_remain = MOD(nfilled_blocks, nprocs_col)
            newdim_col = 2*(nfilled_blocks/nprocs_col)
            IF (n_doubled_items_in_partially_filled_block > ncol_block) THEN
               ! doubled number of columns in a partially filled block does not fit into a single block.
               ! Due to cyclic distribution of ScaLAPACK blocks, an extra block for each core needs to be added
               ! |-----|-----|-----|----|     |-----|-----|-----|-----|-----|-----|-----|-----|-----|---|
               ! |  0  |  1  |  2  |  0 | --> |  0  |  1  |  2  |  0  |  1  |  2  |  0  |  1  |  2  |  0|
               ! |-----|-----|-----|----|     |-----|-----|-----|-----|-----|-----|-----|-----|-----|---|
               !    a     a     a     b          a1    a1    a1    a2    a2    a2    b1  empty empty  b2
               newdim_col = newdim_col + 1

               ! the number of columns which does not fit into the added extra block
               n_doubled_items_in_partially_filled_block = n_doubled_items_in_partially_filled_block - ncol_block
            ELSE IF (nfilled_blocks_remain > 0) THEN
               ! |-----|-----|-----|-----|--|    |-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|
               ! |  0  |  1  |  2  |  0  | 1| -> |  0  |  1  |  2  |  0  |  1  |  2  |  0  |  1  |  2  |  0  |
               ! |-----|-----|-----|-----|--|    |-----|-----|-----|-----|-----|-----|-----|-----|-----|-----|
               !    a     a     a     b    b        a1    a1    a1    a2    a2    a2    b1  b1 b2 empty   b2
               newdim_col = newdim_col + 1
               n_doubled_items_in_partially_filled_block = 0
            END IF

            newdim_col = (newdim_col*nprocs_col + nfilled_blocks_remain)*ncol_block + n_doubled_items_in_partially_filled_block
         END IF
      END IF

      IF (row) THEN
         IF (nrow_global == 0) THEN
            newdim_row = 0
         ELSE
            n_doubled_items_in_partially_filled_block = 2*MOD(nrow_global, nrow_block)
            nfilled_blocks = nrow_global/nrow_block
            nfilled_blocks_remain = MOD(nfilled_blocks, nprocs_row)
            newdim_row = 2*(nfilled_blocks/nprocs_row)
            IF (n_doubled_items_in_partially_filled_block > nrow_block) THEN
               newdim_row = newdim_row + 1
               n_doubled_items_in_partially_filled_block = n_doubled_items_in_partially_filled_block - nrow_block
            ELSE IF (nfilled_blocks_remain > 0) THEN
               newdim_row = newdim_row + 1
               n_doubled_items_in_partially_filled_block = 0
            END IF

            newdim_row = (newdim_row*nprocs_row + nfilled_blocks_remain)*nrow_block + n_doubled_items_in_partially_filled_block
         END IF
      END IF

      ! square_blocks=.FALSE. ensures that matrix blocks of the doubled matrix will have
      ! nrow_block x ncol_block shape even in case of a square doubled matrix
      CALL cp_fm_struct_create(fmstruct=fmstruct, para_env=para_env, &
                               context=context, &
                               nrow_global=newdim_row, &
                               ncol_global=newdim_col, &
                               ncol_block=ncol_block, &
                               nrow_block=nrow_block, &
                               square_blocks=.FALSE.)

   END SUBROUTINE cp_fm_struct_double
! **************************************************************************************************
!> \brief allows to modify the default settings for matrix creation
!> \param nrow_block ...
!> \param ncol_block ...
!> \param force_block ...
! **************************************************************************************************
   SUBROUTINE cp_fm_struct_config(nrow_block, ncol_block, force_block)
      INTEGER, OPTIONAL                                  :: nrow_block, ncol_block
      LOGICAL, OPTIONAL                                  :: force_block

      IF (PRESENT(ncol_block)) optimal_blacs_col_block_size = ncol_block
      IF (PRESENT(nrow_block)) optimal_blacs_row_block_size = nrow_block
      IF (PRESENT(force_block)) force_block_size = force_block

   END SUBROUTINE cp_fm_struct_config

! **************************************************************************************************
!> \brief ...
!> \return ...
! **************************************************************************************************
   FUNCTION cp_fm_struct_get_nrow_block() RESULT(res)
      INTEGER                                            :: res

      res = optimal_blacs_row_block_size
   END FUNCTION cp_fm_struct_get_nrow_block

! **************************************************************************************************
!> \brief ...
!> \return ...
! **************************************************************************************************
   FUNCTION cp_fm_struct_get_ncol_block() RESULT(res)
      INTEGER                                            :: res

      res = optimal_blacs_col_block_size
   END FUNCTION cp_fm_struct_get_ncol_block

END MODULE cp_fm_struct
