!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines for reading and writing restart files.
!> \author Ole Schuett
! **************************************************************************************************
MODULE pao_io
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind
   USE basis_set_types,                 ONLY: gto_basis_set_type
   USE cell_types,                      ONLY: cell_type
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_io_unit,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_p_file,&
                                              cp_print_key_finished_output,&
                                              cp_print_key_should_output,&
                                              cp_print_key_unit_nr
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: &
        dbcsr_convert_dbcsr_to_csr, dbcsr_copy, dbcsr_csr_create_from_dbcsr, &
        dbcsr_csr_dbcsr_blkrow_dist, dbcsr_csr_destroy, dbcsr_csr_type, dbcsr_csr_write, &
        dbcsr_desymmetrize, dbcsr_get_block_p, dbcsr_get_info, dbcsr_has_symmetry, dbcsr_release, &
        dbcsr_type
   USE dm_ls_scf_types,                 ONLY: ls_scf_env_type
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_path_length,&
                                              default_string_length,&
                                              dp
   USE message_passing,                 ONLY: mp_bcast,&
                                              mp_max,&
                                              mp_sum
   USE pao_input,                       ONLY: id2str
   USE pao_param,                       ONLY: pao_param_count
   USE pao_types,                       ONLY: pao_env_type
   USE particle_types,                  ONLY: particle_type
   USE physcon,                         ONLY: angstrom
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              pao_potential_type,&
                                              qs_kind_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'pao_io'

   PUBLIC :: pao_read_restart, pao_write_restart
   PUBLIC :: pao_read_raw, pao_kinds_ensure_equal
   PUBLIC :: pao_ioblock_type, pao_iokind_type
   PUBLIC :: pao_write_ks_matrix_csr, pao_write_s_matrix_csr

   ! data types used by pao_read_raw()
   TYPE pao_ioblock_type
      REAL(dp), DIMENSION(:, :), ALLOCATABLE    :: p
   END TYPE pao_ioblock_type

   TYPE pao_iokind_type
      CHARACTER(LEN=default_string_length)     :: name = ""
      INTEGER                                  :: z = -1
      CHARACTER(LEN=default_string_length)     :: prim_basis_name = ""
      INTEGER                                  :: prim_basis_size = -1
      INTEGER                                  :: pao_basis_size = -1
      INTEGER                                  :: nparams = -1
      TYPE(pao_potential_type), ALLOCATABLE, DIMENSION(:) :: pao_potentials
   END TYPE pao_iokind_type

   INTEGER, PARAMETER, PRIVATE :: file_format_version = 4

CONTAINS

! **************************************************************************************************
!> \brief Reads restart file
!> \param pao ...
!> \param qs_env ...
! **************************************************************************************************
   SUBROUTINE pao_read_restart(pao, qs_env)
      TYPE(pao_env_type), POINTER                        :: pao
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(LEN=default_string_length)               :: param
      INTEGER                                            :: iatom, ikind, natoms
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: atom2kind
      INTEGER, DIMENSION(:), POINTER                     :: col_blk_sizes, row_blk_sizes
      LOGICAL                                            :: found
      REAL(dp)                                           :: diff
      REAL(dp), ALLOCATABLE, DIMENSION(:, :)             :: hmat, positions
      REAL(dp), DIMENSION(:, :), POINTER                 :: block_X, buffer
      TYPE(cell_type), POINTER                           :: cell
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(pao_ioblock_type), ALLOCATABLE, DIMENSION(:)  :: xblocks
      TYPE(pao_iokind_type), ALLOCATABLE, DIMENSION(:)   :: kinds
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set

      CPASSERT(LEN_TRIM(pao%restart_file) > 0)
      IF (pao%iw > 0) WRITE (pao%iw, '(A,A)') " PAO| Reading matrix_X from restart file: ", TRIM(pao%restart_file)

      CALL get_qs_env(qs_env, &
                      para_env=para_env, &
                      natom=natoms, &
                      cell=cell, &
                      particle_set=particle_set)

      ! read and check restart file on first rank only
      IF (para_env%ionode) THEN
         CALL pao_read_raw(pao%restart_file, param, hmat, kinds, atom2kind, positions, xblocks)

         ! check cell
         IF (MAXVAL(ABS(hmat - cell%hmat)) > 1e-10) &
            CPWARN("Restarting from different cell")

         ! check parametrization
         IF (TRIM(param) .NE. TRIM(ADJUSTL(id2str(pao%parameterization)))) &
            CPABORT("Restart PAO parametrization does not match")

         ! check kinds
         DO ikind = 1, SIZE(kinds)
            CALL pao_kinds_ensure_equal(pao, qs_env, ikind, kinds(ikind))
         END DO

         ! check number of atoms
         IF (SIZE(positions, 1) /= natoms) &
            CPABORT("Number of atoms do not match")

         ! check atom2kind
         DO iatom = 1, natoms
            IF (atom2kind(iatom) /= particle_set(iatom)%atomic_kind%kind_number) &
               CPABORT("Restart atomic kinds do not match.")
         END DO

         ! check positions, warning only
         diff = 0.0_dp
         DO iatom = 1, natoms
            diff = MAX(diff, MAXVAL(ABS(positions(iatom, :) - particle_set(iatom)%r)))
         END DO
         IF (diff > 1e-10) &
            CPWARN("Restarting from different atom positions")

      END IF

      ! scatter xblocks across ranks to fill pao%matrix_X
      ! this could probably be done more efficiently
      CALL dbcsr_get_info(pao%matrix_X, row_blk_size=row_blk_sizes, col_blk_size=col_blk_sizes)
      DO iatom = 1, natoms
         ALLOCATE (buffer(row_blk_sizes(iatom), col_blk_sizes(iatom)))
         IF (para_env%ionode) THEN
            CPASSERT(row_blk_sizes(iatom) == SIZE(xblocks(iatom)%p, 1))
            CPASSERT(col_blk_sizes(iatom) == SIZE(xblocks(iatom)%p, 2))
            buffer = xblocks(iatom)%p
         END IF
         CALL mp_bcast(buffer, para_env%source, para_env%group)
         CALL dbcsr_get_block_p(matrix=pao%matrix_X, row=iatom, col=iatom, block=block_X, found=found)
         IF (ASSOCIATED(block_X)) &
            block_X = buffer
         DEALLOCATE (buffer)
      END DO

      ! ALLOCATABLEs deallocate themselves

   END SUBROUTINE pao_read_restart

! **************************************************************************************************
!> \brief Reads a restart file into temporary datastructures
!> \param filename ...
!> \param param ...
!> \param hmat ...
!> \param kinds ...
!> \param atom2kind ...
!> \param positions ...
!> \param xblocks ...
!> \param ml_range ...
! **************************************************************************************************
   SUBROUTINE pao_read_raw(filename, param, hmat, kinds, atom2kind, positions, xblocks, ml_range)
      CHARACTER(LEN=default_path_length), INTENT(IN)     :: filename
      CHARACTER(LEN=default_string_length), INTENT(OUT)  :: param
      REAL(dp), ALLOCATABLE, DIMENSION(:, :)             :: hmat
      TYPE(pao_iokind_type), ALLOCATABLE, DIMENSION(:)   :: kinds
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: atom2kind
      REAL(dp), ALLOCATABLE, DIMENSION(:, :)             :: positions
      TYPE(pao_ioblock_type), ALLOCATABLE, DIMENSION(:)  :: xblocks
      INTEGER, DIMENSION(2), INTENT(OUT), OPTIONAL       :: ml_range

      CHARACTER(LEN=default_string_length)               :: label, str_in
      INTEGER                                            :: i1, i2, iatom, ikind, ipot, natoms, &
                                                            nkinds, nparams, unit_nr, xblocks_read
      REAL(dp)                                           :: r1, r2
      REAL(dp), DIMENSION(3)                             :: pos_in
      REAL(dp), DIMENSION(3, 3)                          :: hmat_angstrom

      CPASSERT(.NOT. ALLOCATED(hmat))
      CPASSERT(.NOT. ALLOCATED(kinds))
      CPASSERT(.NOT. ALLOCATED(atom2kind))
      CPASSERT(.NOT. ALLOCATED(positions))
      CPASSERT(.NOT. ALLOCATED(xblocks))

      natoms = -1
      nkinds = -1
      xblocks_read = 0

      CALL open_file(file_name=filename, file_status="OLD", file_form="FORMATTED", &
                     file_action="READ", unit_number=unit_nr)

      ! check if file starts with proper header !TODO: introduce a more unique header
      READ (unit_nr, fmt=*) label, i1
      IF (TRIM(label) /= "Version") &
         CPABORT("PAO restart file appears to be corrupted.")
      IF (i1 /= file_format_version) CPABORT("Restart PAO file format version is wrong")

      DO WHILE (.TRUE.)
         READ (unit_nr, fmt=*) label
         BACKSPACE (unit_nr)

         IF (TRIM(label) == "Parametrization") THEN
            READ (unit_nr, fmt=*) label, str_in
            param = str_in

         ELSE IF (TRIM(label) == "Cell") THEN
            READ (unit_nr, fmt=*) label, hmat_angstrom
            ALLOCATE (hmat(3, 3))
            hmat(:, :) = hmat_angstrom(:, :)/angstrom

         ELSE IF (TRIM(label) == "Nkinds") THEN
            READ (unit_nr, fmt=*) label, nkinds
            ALLOCATE (kinds(nkinds))

         ELSE IF (TRIM(label) == "Kind") THEN
            READ (unit_nr, fmt=*) label, ikind, str_in, i1
            CPASSERT(ALLOCATED(kinds))
            kinds(ikind)%name = str_in
            kinds(ikind)%z = i1

         ELSE IF (TRIM(label) == "PrimBasis") THEN
            READ (unit_nr, fmt=*) label, ikind, i1, str_in
            CPASSERT(ALLOCATED(kinds))
            kinds(ikind)%prim_basis_size = i1
            kinds(ikind)%prim_basis_name = str_in

         ELSE IF (TRIM(label) == "PaoBasis") THEN
            READ (unit_nr, fmt=*) label, ikind, i1
            CPASSERT(ALLOCATED(kinds))
            kinds(ikind)%pao_basis_size = i1

         ELSE IF (TRIM(label) == "NPaoPotentials") THEN
            READ (unit_nr, fmt=*) label, ikind, i1
            CPASSERT(ALLOCATED(kinds))
            ALLOCATE (kinds(ikind)%pao_potentials(i1))

         ELSE IF (TRIM(label) == "PaoPotential") THEN
            READ (unit_nr, fmt=*) label, ikind, ipot, i1, i2, r1, r2
            CPASSERT(ALLOCATED(kinds(ikind)%pao_potentials))
            kinds(ikind)%pao_potentials(ipot)%maxl = i1
            kinds(ikind)%pao_potentials(ipot)%max_projector = i2
            kinds(ikind)%pao_potentials(ipot)%beta = r1
            kinds(ikind)%pao_potentials(ipot)%weight = r2

         ELSE IF (TRIM(label) == "NParams") THEN
            READ (unit_nr, fmt=*) label, ikind, i1
            CPASSERT(ALLOCATED(kinds))
            kinds(ikind)%nparams = i1

         ELSE IF (TRIM(label) == "Natoms") THEN
            READ (unit_nr, fmt=*) label, natoms
            ALLOCATE (positions(natoms, 3), atom2kind(natoms), xblocks(natoms))
            positions = 0.0_dp; atom2kind = -1
            IF (PRESENT(ml_range)) ml_range = (/1, natoms/)

         ELSE IF (TRIM(label) == "MLRange") THEN
            ! Natoms entry has to come first
            CPASSERT(natoms > 0)
            ! range of atoms whose xblocks are used for machine learning
            READ (unit_nr, fmt=*) label, i1, i2
            IF (PRESENT(ml_range)) ml_range = (/i1, i2/)

         ELSE IF (TRIM(label) == "Atom") THEN
            READ (unit_nr, fmt=*) label, iatom, str_in, pos_in
            CPASSERT(ALLOCATED(kinds))
            DO ikind = 1, nkinds
               IF (TRIM(kinds(ikind)%name) .EQ. TRIM(str_in)) EXIT
            END DO
            CPASSERT(ALLOCATED(atom2kind) .AND. ALLOCATED(positions))
            atom2kind(iatom) = ikind
            positions(iatom, :) = pos_in/angstrom

         ELSE IF (TRIM(label) == "Xblock") THEN
            READ (unit_nr, fmt=*) label, iatom
            CPASSERT(ALLOCATED(kinds) .AND. ALLOCATED(atom2kind))
            ikind = atom2kind(iatom)
            nparams = kinds(ikind)%nparams
            CPASSERT(nparams >= 0)
            ALLOCATE (xblocks(iatom)%p(nparams, 1))
            BACKSPACE (unit_nr)
            READ (unit_nr, fmt=*) label, iatom, xblocks(iatom)%p
            xblocks_read = xblocks_read + 1
            CPASSERT(iatom == xblocks_read) ! ensure blocks are read in order

         ELSE IF (TRIM(label) == "THE_END") THEN
            EXIT
         ELSE
            !CPWARN("Skipping restart header with label: "//TRIM(label))
            READ (unit_nr, fmt=*) label ! just read again and ignore
         END IF
      END DO
      CALL close_file(unit_number=unit_nr)

      CPASSERT(xblocks_read == natoms) ! ensure we read all blocks

   END SUBROUTINE pao_read_raw

! **************************************************************************************************
!> \brief Ensure that the kind read from the restart is equal to the kind curretly in use.
!> \param pao ...
!> \param qs_env ...
!> \param ikind ...
!> \param pao_kind ...
! **************************************************************************************************
   SUBROUTINE pao_kinds_ensure_equal(pao, qs_env, ikind, pao_kind)
      TYPE(pao_env_type), POINTER                        :: pao
      TYPE(qs_environment_type), POINTER                 :: qs_env
      INTEGER, INTENT(IN)                                :: ikind
      TYPE(pao_iokind_type), INTENT(IN)                  :: pao_kind

      CHARACTER(LEN=default_string_length)               :: name
      INTEGER                                            :: ipot, nparams, pao_basis_size, z
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(gto_basis_set_type), POINTER                  :: basis_set
      TYPE(pao_potential_type), DIMENSION(:), POINTER    :: pao_potentials
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set

      CALL get_qs_env(qs_env, &
                      atomic_kind_set=atomic_kind_set, &
                      qs_kind_set=qs_kind_set)

      IF (ikind > SIZE(atomic_kind_set) .OR. ikind > SIZE(qs_kind_set)) &
         CPABORT("Some kinds are missing.")

      CALL get_atomic_kind(atomic_kind_set(ikind), z=z, name=name)
      CALL get_qs_kind(qs_kind_set(ikind), &
                       basis_set=basis_set, &
                       pao_basis_size=pao_basis_size, &
                       pao_potentials=pao_potentials)
      CALL pao_param_count(pao, qs_env, ikind=ikind, nparams=nparams)

      IF (pao_kind%nparams /= nparams) &
         CPABORT("Number of parameters do not match")
      IF (TRIM(pao_kind%name) .NE. TRIM(name)) &
         CPABORT("Kind names do not match")
      IF (pao_kind%z /= z) &
         CPABORT("Atomic numbers do not match")
      IF (TRIM(pao_kind%prim_basis_name) .NE. TRIM(basis_set%name)) &
         CPABORT("Primary Basis-set name does not match")
      IF (pao_kind%prim_basis_size /= basis_set%nsgf) &
         CPABORT("Primary Basis-set size does not match")
      IF (pao_kind%pao_basis_size /= pao_basis_size) &
         CPABORT("PAO basis size does not match")
      IF (SIZE(pao_kind%pao_potentials) /= SIZE(pao_potentials)) &
         CPABORT("Number of PAO_POTENTIALS does not match")

      DO ipot = 1, SIZE(pao_potentials)
         IF (pao_kind%pao_potentials(ipot)%maxl /= pao_potentials(ipot)%maxl) &
            CPABORT("PAO_POT_MAXL does not match")
         IF (pao_kind%pao_potentials(ipot)%max_projector /= pao_potentials(ipot)%max_projector) &
            CPABORT("PAO_POT_MAX_PROJECTOR does not match")
         IF (pao_kind%pao_potentials(ipot)%beta /= pao_potentials(ipot)%beta) &
            CPWARN("PAO_POT_BETA does not match")
         IF (pao_kind%pao_potentials(ipot)%weight /= pao_potentials(ipot)%weight) &
            CPWARN("PAO_POT_WEIGHT does not match")
      END DO

   END SUBROUTINE pao_kinds_ensure_equal

! **************************************************************************************************
!> \brief Writes restart file
!> \param pao ...
!> \param qs_env ...
!> \param energy ...
! **************************************************************************************************
   SUBROUTINE pao_write_restart(pao, qs_env, energy)
      TYPE(pao_env_type), POINTER                        :: pao
      TYPE(qs_environment_type), POINTER                 :: qs_env
      REAL(dp)                                           :: energy

      CHARACTER(len=*), PARAMETER :: printkey_section = 'DFT%LS_SCF%PAO%PRINT%RESTART', &
         routineN = 'pao_write_restart'

      INTEGER                                            :: handle, unit_max, unit_nr
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(section_vals_type), POINTER                   :: input

      CALL timeset(routineN, handle)
      logger => cp_get_default_logger()

      CALL get_qs_env(qs_env, input=input, para_env=para_env)

      ! open file
      unit_nr = cp_print_key_unit_nr(logger, &
                                     input, &
                                     printkey_section, &
                                     extension=".pao", &
                                     file_action="WRITE", &
                                     file_position="REWIND", &
                                     file_status="UNKNOWN", &
                                     do_backup=.TRUE.)

      ! although just rank-0 writes the trajectory it requires collective MPI calls
      unit_max = unit_nr
      CALL mp_max(unit_max, para_env%group)
      IF (unit_max > 0) THEN
         IF (pao%iw > 0) WRITE (pao%iw, '(A,A)') " PAO| Writing restart file."
         IF (unit_nr > 0) &
            CALL write_restart_header(pao, qs_env, energy, unit_nr)

         CALL pao_write_diagonal_blocks(para_env, pao%matrix_X, "Xblock", unit_nr)

      END IF

      ! close file
      IF (unit_nr > 0) WRITE (unit_nr, '(A)') "THE_END"
      CALL cp_print_key_finished_output(unit_nr, logger, input, printkey_section)

      CALL timestop(handle)
   END SUBROUTINE pao_write_restart

! **************************************************************************************************
!> \brief Write the digonal blocks of given DBCSR matrix into the provided unit_nr
!> \param para_env ...
!> \param matrix ...
!> \param label ...
!> \param unit_nr ...
! **************************************************************************************************
   SUBROUTINE pao_write_diagonal_blocks(para_env, matrix, label, unit_nr)
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_type)                                   :: matrix
      CHARACTER(LEN=*), INTENT(IN)                       :: label
      INTEGER, INTENT(IN)                                :: unit_nr

      INTEGER                                            :: iatom, natoms
      INTEGER, DIMENSION(:), POINTER                     :: col_blk_sizes, row_blk_sizes
      LOGICAL                                            :: found
      REAL(dp), DIMENSION(:, :), POINTER                 :: local_block, mpi_buffer

      !TODO: this is a serial algorithm
      CALL dbcsr_get_info(matrix, row_blk_size=row_blk_sizes, col_blk_size=col_blk_sizes)
      CPASSERT(SIZE(row_blk_sizes) == SIZE(col_blk_sizes))
      natoms = SIZE(row_blk_sizes)

      DO iatom = 1, natoms
         ALLOCATE (mpi_buffer(row_blk_sizes(iatom), col_blk_sizes(iatom)))
         NULLIFY (local_block)
         CALL dbcsr_get_block_p(matrix=matrix, row=iatom, col=iatom, block=local_block, found=found)
         IF (ASSOCIATED(local_block)) THEN
            IF (SIZE(local_block) > 0) & ! catch corner-case
               mpi_buffer(:, :) = local_block(:, :)
         ELSE
            mpi_buffer(:, :) = 0.0_dp
         END IF

         CALL mp_sum(mpi_buffer, para_env%group)
         IF (unit_nr > 0) THEN
            WRITE (unit_nr, fmt="(A,1X,I10,1X)", advance='no') label, iatom
            WRITE (unit_nr, *) mpi_buffer
         END IF
         DEALLOCATE (mpi_buffer)
      END DO

      ! flush
      IF (unit_nr > 0) FLUSH (unit_nr)

   END SUBROUTINE pao_write_diagonal_blocks

! **************************************************************************************************
!> \brief Writes header of restart file
!> \param pao ...
!> \param qs_env ...
!> \param energy ...
!> \param unit_nr ...
! **************************************************************************************************
   SUBROUTINE write_restart_header(pao, qs_env, energy, unit_nr)
      TYPE(pao_env_type), POINTER                        :: pao
      TYPE(qs_environment_type), POINTER                 :: qs_env
      REAL(dp)                                           :: energy
      INTEGER, INTENT(IN)                                :: unit_nr

      CHARACTER(LEN=default_string_length)               :: kindname
      INTEGER                                            :: iatom, ikind, ipot, nparams, &
                                                            pao_basis_size, z
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cell_type), POINTER                           :: cell
      TYPE(gto_basis_set_type), POINTER                  :: basis_set
      TYPE(pao_potential_type), DIMENSION(:), POINTER    :: pao_potentials
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set

      CALL get_qs_env(qs_env, &
                      cell=cell, &
                      particle_set=particle_set, &
                      atomic_kind_set=atomic_kind_set, &
                      qs_kind_set=qs_kind_set)

      WRITE (unit_nr, "(A,5X,I0)") "Version", file_format_version
      WRITE (unit_nr, "(A,5X,F20.10)") "Energy", energy
      WRITE (unit_nr, "(A,5X,I0)") "Step", pao%istep
      WRITE (unit_nr, "(A,5X,A10)") "Parametrization", id2str(pao%parameterization)

      ! write kinds
      WRITE (unit_nr, "(A,5X,I0)") "Nkinds", SIZE(atomic_kind_set)
      DO ikind = 1, SIZE(atomic_kind_set)
         CALL get_atomic_kind(atomic_kind_set(ikind), name=kindname, z=z)
         CALL get_qs_kind(qs_kind_set(ikind), &
                          pao_basis_size=pao_basis_size, &
                          pao_potentials=pao_potentials, &
                          basis_set=basis_set)
         CALL pao_param_count(pao, qs_env, ikind, nparams)
         WRITE (unit_nr, "(A,5X,I10,1X,A,1X,I3)") "Kind", ikind, TRIM(kindname), z
         WRITE (unit_nr, "(A,5X,I10,1X,I3)") "NParams", ikind, nparams
         WRITE (unit_nr, "(A,5X,I10,1X,I10,1X,A)") "PrimBasis", ikind, basis_set%nsgf, TRIM(basis_set%name)
         WRITE (unit_nr, "(A,5X,I10,1X,I3)") "PaoBasis", ikind, pao_basis_size
         WRITE (unit_nr, "(A,5X,I10,1X,I3)") "NPaoPotentials", ikind, SIZE(pao_potentials)
         DO ipot = 1, SIZE(pao_potentials)
            WRITE (unit_nr, "(A,5X,I10,1X,I3)", advance='no') "PaoPotential", ikind, ipot
            WRITE (unit_nr, "(1X,I3)", advance='no') pao_potentials(ipot)%maxl
            WRITE (unit_nr, "(1X,I3)", advance='no') pao_potentials(ipot)%max_projector
            WRITE (unit_nr, "(1X,F20.16)", advance='no') pao_potentials(ipot)%beta
            WRITE (unit_nr, "(1X,F20.16)") pao_potentials(ipot)%weight
         END DO
      END DO

      ! write cell
      WRITE (unit_nr, fmt="(A,5X)", advance='no') "Cell"
      WRITE (unit_nr, *) cell%hmat*angstrom

      ! write atoms
      WRITE (unit_nr, "(A,5X,I0)") "Natoms", SIZE(particle_set)
      DO iatom = 1, SIZE(particle_set)
         kindname = particle_set(iatom)%atomic_kind%name
         WRITE (unit_nr, fmt="(A,5X,I10,5X,A,1X)", advance='no') "Atom ", iatom, TRIM(kindname)
         WRITE (unit_nr, *) particle_set(iatom)%r*angstrom
      END DO

   END SUBROUTINE write_restart_header

!**************************************************************************************************
!> \brief writing the KS matrix (in terms of the PAO basis) in csr format into a file
!> \param qs_env qs environment
!> \param ls_scf_env ls environment
!> \author Mohammad Hossein Bani-Hashemian
! **************************************************************************************************
   SUBROUTINE pao_write_ks_matrix_csr(qs_env, ls_scf_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(ls_scf_env_type), TARGET                      :: ls_scf_env

      CHARACTER(len=*), PARAMETER :: routineN = 'pao_write_ks_matrix_csr'

      CHARACTER(LEN=default_path_length)                 :: file_name, fileformat
      INTEGER                                            :: handle, ispin, output_unit, unit_nr
      LOGICAL                                            :: bin, do_kpoints, do_ks_csr_write, uptr
      REAL(KIND=dp)                                      :: thld
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_csr_type)                               :: ks_mat_csr
      TYPE(dbcsr_type)                                   :: matrix_ks_nosym
      TYPE(section_vals_type), POINTER                   :: dft_section, input

      CALL timeset(routineN, handle)

      NULLIFY (dft_section)

      logger => cp_get_default_logger()
      output_unit = cp_logger_get_default_io_unit(logger)

      CALL get_qs_env(qs_env, input=input)
      dft_section => section_vals_get_subs_vals(input, "DFT")
      do_ks_csr_write = BTEST(cp_print_key_should_output(logger%iter_info, dft_section, &
                                                         "PRINT%KS_CSR_WRITE"), cp_p_file)

      ! NOTE: k-points has to be treated differently later. k-points has KS matrix as double pointer.
      CALL get_qs_env(qs_env=qs_env, do_kpoints=do_kpoints)

      IF (do_ks_csr_write .AND. (.NOT. do_kpoints)) THEN
         CALL section_vals_val_get(dft_section, "PRINT%KS_CSR_WRITE%THRESHOLD", r_val=thld)
         CALL section_vals_val_get(dft_section, "PRINT%KS_CSR_WRITE%UPPER_TRIANGULAR", l_val=uptr)
         CALL section_vals_val_get(dft_section, "PRINT%KS_CSR_WRITE%BINARY", l_val=bin)

         IF (bin) THEN
            fileformat = "UNFORMATTED"
         ELSE
            fileformat = "FORMATTED"
         END IF

         DO ispin = 1, SIZE(ls_scf_env%matrix_ks)

            IF (dbcsr_has_symmetry(ls_scf_env%matrix_ks(ispin))) THEN
               CALL dbcsr_desymmetrize(ls_scf_env%matrix_ks(ispin), matrix_ks_nosym)
            ELSE
               CALL dbcsr_copy(matrix_ks_nosym, ls_scf_env%matrix_ks(ispin))
            END IF

            CALL dbcsr_csr_create_from_dbcsr(matrix_ks_nosym, ks_mat_csr, dbcsr_csr_dbcsr_blkrow_dist)
            CALL dbcsr_convert_dbcsr_to_csr(matrix_ks_nosym, ks_mat_csr)

            WRITE (file_name, '(A,I0)') "PAO_KS_SPIN_", ispin
            unit_nr = cp_print_key_unit_nr(logger, dft_section, "PRINT%KS_CSR_WRITE", &
                                           extension=".csr", middle_name=TRIM(file_name), &
                                           file_status="REPLACE", file_form=fileformat)
            CALL dbcsr_csr_write(ks_mat_csr, unit_nr, upper_triangle=uptr, threshold=thld, binary=bin)

            CALL cp_print_key_finished_output(unit_nr, logger, dft_section, "PRINT%KS_CSR_WRITE")

            CALL dbcsr_csr_destroy(ks_mat_csr)
            CALL dbcsr_release(matrix_ks_nosym)
         END DO
      END IF

      CALL timestop(handle)

   END SUBROUTINE pao_write_ks_matrix_csr

!**************************************************************************************************
!> \brief writing the overlap matrix (in terms of the PAO basis) in csr format into a file
!> \param qs_env qs environment
!> \param ls_scf_env ls environment
!> \author Mohammad Hossein Bani-Hashemian
! **************************************************************************************************
   SUBROUTINE pao_write_s_matrix_csr(qs_env, ls_scf_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(ls_scf_env_type), TARGET                      :: ls_scf_env

      CHARACTER(len=*), PARAMETER :: routineN = 'pao_write_s_matrix_csr'

      CHARACTER(LEN=default_path_length)                 :: file_name, fileformat
      INTEGER                                            :: handle, output_unit, unit_nr
      LOGICAL                                            :: bin, do_kpoints, do_s_csr_write, uptr
      REAL(KIND=dp)                                      :: thld
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_csr_type)                               :: s_mat_csr
      TYPE(dbcsr_type)                                   :: matrix_s_nosym
      TYPE(section_vals_type), POINTER                   :: dft_section, input

      CALL timeset(routineN, handle)

      NULLIFY (dft_section)

      logger => cp_get_default_logger()
      output_unit = cp_logger_get_default_io_unit(logger)

      CALL get_qs_env(qs_env, input=input)
      dft_section => section_vals_get_subs_vals(input, "DFT")
      do_s_csr_write = BTEST(cp_print_key_should_output(logger%iter_info, dft_section, &
                                                        "PRINT%S_CSR_WRITE"), cp_p_file)

      ! NOTE: k-points has to be treated differently later. k-points has overlap matrix as double pointer.
      CALL get_qs_env(qs_env=qs_env, do_kpoints=do_kpoints)

      IF (do_s_csr_write .AND. (.NOT. do_kpoints)) THEN
         CALL section_vals_val_get(dft_section, "PRINT%S_CSR_WRITE%THRESHOLD", r_val=thld)
         CALL section_vals_val_get(dft_section, "PRINT%S_CSR_WRITE%UPPER_TRIANGULAR", l_val=uptr)
         CALL section_vals_val_get(dft_section, "PRINT%S_CSR_WRITE%BINARY", l_val=bin)

         IF (bin) THEN
            fileformat = "UNFORMATTED"
         ELSE
            fileformat = "FORMATTED"
         END IF

         IF (dbcsr_has_symmetry(ls_scf_env%matrix_s)) THEN
            CALL dbcsr_desymmetrize(ls_scf_env%matrix_s, matrix_s_nosym)
         ELSE
            CALL dbcsr_copy(matrix_s_nosym, ls_scf_env%matrix_s)
         END IF

         CALL dbcsr_csr_create_from_dbcsr(matrix_s_nosym, s_mat_csr, dbcsr_csr_dbcsr_blkrow_dist)
         CALL dbcsr_convert_dbcsr_to_csr(matrix_s_nosym, s_mat_csr)

         WRITE (file_name, '(A,I0)') "PAO_S"
         unit_nr = cp_print_key_unit_nr(logger, dft_section, "PRINT%S_CSR_WRITE", &
                                        extension=".csr", middle_name=TRIM(file_name), &
                                        file_status="REPLACE", file_form=fileformat)
         CALL dbcsr_csr_write(s_mat_csr, unit_nr, upper_triangle=uptr, threshold=thld, binary=bin)

         CALL cp_print_key_finished_output(unit_nr, logger, dft_section, "PRINT%S_CSR_WRITE")

         CALL dbcsr_csr_destroy(s_mat_csr)
         CALL dbcsr_release(matrix_s_nosym)
      END IF

      CALL timestop(handle)

   END SUBROUTINE pao_write_s_matrix_csr

END MODULE pao_io
