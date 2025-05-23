!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Methods and functions on the EIP environment
!> \par History
!>      03.2006 initial create [tdk]
!> \author Thomas D. Kuehne (tkuehne@phys.chem.ethz.ch)
! **************************************************************************************************
MODULE eip_environment
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind
   USE cell_methods,                    ONLY: read_cell,&
                                              write_cell
   USE cell_types,                      ONLY: cell_release,&
                                              cell_type,&
                                              get_cell
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_subsys_methods,               ONLY: cp_subsys_create
   USE cp_subsys_types,                 ONLY: cp_subsys_set,&
                                              cp_subsys_type
   USE distribution_1d_types,           ONLY: distribution_1d_release,&
                                              distribution_1d_type
   USE distribution_methods,            ONLY: distribute_molecules_1d
   USE eip_environment_types,           ONLY: eip_env_set,&
                                              eip_environment_type
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE molecule_kind_types,             ONLY: molecule_kind_type,&
                                              write_molecule_kind_set
   USE molecule_types,                  ONLY: molecule_type
   USE particle_methods,                ONLY: write_fist_particle_coordinates,&
                                              write_particle_distances,&
                                              write_structure_data
   USE particle_types,                  ONLY: particle_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! *** Global parameters ***

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'eip_environment'

! *** Public subroutines ***

   PUBLIC :: eip_init

CONTAINS

! **************************************************************************************************
!> \brief Initialize the eip environment
!> \param eip_env The eip environment to retain
!> \param root_section ...
!> \param para_env ...
!> \param force_env_section ...
!> \param subsys_section ...
!> \par History
!>      03.2006 initial create [tdk]
!> \author Thomas D. Kuehne (tkuehne@phys.chem.ethz.ch)
! **************************************************************************************************
   SUBROUTINE eip_init(eip_env, root_section, para_env, force_env_section, &
                       subsys_section)
      TYPE(eip_environment_type), POINTER                :: eip_env
      TYPE(section_vals_type), POINTER                   :: root_section
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(section_vals_type), POINTER                   :: force_env_section, subsys_section

      CHARACTER(len=*), PARAMETER                        :: routineN = 'eip_init'

      INTEGER                                            :: handle
      LOGICAL                                            :: use_ref_cell
      REAL(KIND=dp), DIMENSION(3)                        :: abc
      TYPE(cell_type), POINTER                           :: cell, cell_ref
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(section_vals_type), POINTER                   :: cell_section, colvar_section, eip_section

      CALL timeset(routineN, handle)

      CPASSERT(ASSOCIATED(eip_env))

      ! nullifying  pointers
      NULLIFY (cell_section, colvar_section, eip_section, cell, cell_ref, &
               subsys)

      IF (.NOT. ASSOCIATED(subsys_section)) THEN
         subsys_section => section_vals_get_subs_vals(force_env_section, "SUBSYS")
      END IF
      cell_section => section_vals_get_subs_vals(subsys_section, "CELL")
      colvar_section => section_vals_get_subs_vals(subsys_section, "COLVAR")
      eip_section => section_vals_get_subs_vals(force_env_section, "EIP")

      CALL eip_env_set(eip_env=eip_env, eip_input=eip_section, &
                       force_env_input=force_env_section)

      CALL read_cell(cell=cell, cell_ref=cell_ref, use_ref_cell=use_ref_cell, cell_section=cell_section, &
                     para_env=para_env)
      CALL get_cell(cell=cell, abc=abc)
      CALL write_cell(cell=cell, subsys_section=subsys_section)

      CALL cp_subsys_create(subsys, para_env, root_section)

      CALL eip_init_subsys(eip_env=eip_env, subsys=subsys, cell=cell, &
                           cell_ref=cell_ref, use_ref_cell=use_ref_cell, &
                           subsys_section=subsys_section)

      CALL cell_release(cell)
      CALL cell_release(cell_ref)

      CALL timestop(handle)

   END SUBROUTINE eip_init

! **************************************************************************************************
!> \brief Initialize the eip environment
!> \param eip_env The eip environment of matter
!> \param subsys the subsys
!> \param cell Pointer to the actual simulation cell
!> \param cell_ref Pointer to the reference cell, used e.g. in NPT simulations
!> \param use_ref_cell Logical which indicates if cell_ref is in use
!> \param subsys_section ...
!> \par History
!>      03.2006 initial create [tdk]
!> \author Thomas D. Kuehne (tkuehne@phys.chem.ethz.ch)
! **************************************************************************************************
   SUBROUTINE eip_init_subsys(eip_env, subsys, cell, cell_ref, use_ref_cell, subsys_section)
      TYPE(eip_environment_type), POINTER                :: eip_env
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(cell_type), POINTER                           :: cell, cell_ref
      LOGICAL, INTENT(in)                                :: use_ref_cell
      TYPE(section_vals_type), POINTER                   :: subsys_section

      CHARACTER(len=*), PARAMETER                        :: routineN = 'eip_init_subsys'

      INTEGER                                            :: handle, natom
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(distribution_1d_type), POINTER                :: local_molecules, local_particles
      TYPE(molecule_kind_type), DIMENSION(:), POINTER    :: molecule_kind_set
      TYPE(molecule_type), DIMENSION(:), POINTER         :: molecule_set
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set

!   ------------------------------------------------------------------------

      CALL timeset(routineN, handle)

      NULLIFY (atomic_kind_set, molecule_kind_set, particle_set, molecule_set, &
               local_molecules, local_particles)

      particle_set => subsys%particles%els
      atomic_kind_set => subsys%atomic_kinds%els
      molecule_kind_set => subsys%molecule_kinds%els
      molecule_set => subsys%molecules%els

!   *** Print the molecule kind set ***
      CALL write_molecule_kind_set(molecule_kind_set, subsys_section)

!   *** Print the atomic coordinates
      CALL write_fist_particle_coordinates(particle_set, subsys_section)
      CALL write_particle_distances(particle_set, cell=cell, &
                                    subsys_section=subsys_section)
      CALL write_structure_data(particle_set, cell=cell, &
                                input_section=subsys_section)

!   *** Distribute molecules and atoms using the new data structures ***
      CALL distribute_molecules_1d(atomic_kind_set=atomic_kind_set, &
                                   particle_set=particle_set, &
                                   local_particles=local_particles, &
                                   molecule_kind_set=molecule_kind_set, &
                                   molecule_set=molecule_set, &
                                   local_molecules=local_molecules, &
                                   force_env_section=eip_env%force_env_input)

      natom = SIZE(particle_set)

      ALLOCATE (eip_env%eip_forces(3, natom))

      eip_env%eip_forces(:, :) = 0.0_dp

      CALL cp_subsys_set(subsys, cell=cell)
      CALL eip_env_set(eip_env=eip_env, subsys=subsys, &
                       cell_ref=cell_ref, use_ref_cell=use_ref_cell, &
                       local_molecules=local_molecules, &
                       local_particles=local_particles)

      CALL distribution_1d_release(local_particles)
      CALL distribution_1d_release(local_molecules)

      CALL eip_init_model(eip_env=eip_env)

      CALL timestop(handle)

   END SUBROUTINE eip_init_subsys

! **************************************************************************************************
!> \brief Initialize the empirical interatomic potnetial (force field) model
!> \param eip_env The eip environment to retain
!> \par History
!>      03.2006 initial create [tdk]
!> \author Thomas D. Kuehne (tkuehne@phys.chem.ethz.ch)
! **************************************************************************************************
   SUBROUTINE eip_init_model(eip_env)
      TYPE(eip_environment_type), POINTER                :: eip_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'eip_init_model'

      CHARACTER(LEN=default_string_length)               :: eip_atomic_kind_name
      INTEGER                                            :: handle, i
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(atomic_kind_type), POINTER                    :: atomic_kind_ptr
      TYPE(section_vals_type), POINTER                   :: eip_section

!   ------------------------------------------------------------------------

      CALL timeset(routineN, handle)

      NULLIFY (atomic_kind_set, atomic_kind_ptr, eip_section)

      eip_section => section_vals_get_subs_vals(eip_env%force_env_input, &
                                                "EIP")

      atomic_kind_set => eip_env%subsys%atomic_kinds%els

      ! loop over all kinds
      DO i = 1, SIZE(atomic_kind_set)
         atomic_kind_ptr => eip_env%subsys%atomic_kinds%els(i)
         CALL get_atomic_kind(atomic_kind=atomic_kind_ptr, &
                              name=eip_atomic_kind_name)
         SELECT CASE (eip_atomic_kind_name)
         CASE ("SI", "Si")
            CALL section_vals_val_get(section_vals=eip_section, &
                                      keyword_name="EIP-Model", &
                                      i_val=eip_env%eip_model)
         CASE DEFAULT
            CALL cp_abort(__LOCATION__, &
                          "EIP models for other elements"// &
                          "than Si isn't implemented yet.")
         END SELECT
      END DO

      CALL timestop(handle)

   END SUBROUTINE eip_init_model

END MODULE eip_environment
