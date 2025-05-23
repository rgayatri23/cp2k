!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief initialize fist environment
!> \author CJM
! **************************************************************************************************
MODULE fist_environment
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind_set
   USE bibliography,                    ONLY: Devynck2012,&
                                              Dick1958,&
                                              Mitchell1993,&
                                              cite_reference
   USE cell_methods,                    ONLY: read_cell,&
                                              write_cell
   USE cell_types,                      ONLY: cell_release,&
                                              cell_type,&
                                              get_cell
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_subsys_methods,               ONLY: cp_subsys_create
   USE cp_subsys_types,                 ONLY: cp_subsys_set,&
                                              cp_subsys_type
   USE cp_symmetry,                     ONLY: write_symmetry
   USE distribution_1d_types,           ONLY: distribution_1d_release,&
                                              distribution_1d_type
   USE distribution_methods,            ONLY: distribute_molecules_1d
   USE ewald_environment_types,         ONLY: ewald_env_create,&
                                              ewald_env_get,&
                                              ewald_env_set,&
                                              ewald_environment_type,&
                                              read_ewald_section
   USE ewald_pw_methods,                ONLY: ewald_pw_grid_update
   USE ewald_pw_types,                  ONLY: ewald_pw_create,&
                                              ewald_pw_type
   USE exclusion_types,                 ONLY: exclusion_type
   USE fist_efield_types,               ONLY: fist_efield_type,&
                                              read_efield_section
   USE fist_energy_types,               ONLY: allocate_fist_energy,&
                                              fist_energy_type
   USE fist_environment_types,          ONLY: fist_env_get,&
                                              fist_env_set,&
                                              fist_environment_type
   USE fist_nonbond_env_types,          ONLY: fist_nonbond_env_type
   USE force_fields,                    ONLY: force_field_control
   USE header,                          ONLY: fist_header
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type
   USE kinds,                           ONLY: dp
   USE molecule_kind_types,             ONLY: molecule_kind_type,&
                                              write_molecule_kind_set
   USE molecule_types,                  ONLY: molecule_type
   USE multipole_types,                 ONLY: create_multipole_type,&
                                              multipole_type
   USE particle_list_types,             ONLY: particle_list_create,&
                                              particle_list_release,&
                                              particle_list_type
   USE particle_methods,                ONLY: write_fist_particle_coordinates,&
                                              write_particle_distances,&
                                              write_structure_data
   USE particle_types,                  ONLY: particle_type
   USE qmmm_types_low,                  ONLY: qmmm_env_mm_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'fist_environment'
   PUBLIC :: fist_init

CONTAINS
! **************************************************************************************************
!> \brief reads the input and database file for fist
!> \param fist_env ...
!> \param root_section ...
!> \param para_env ...
!> \param force_env_section ...
!> \param subsys_section ...
!> \param use_motion_section ...
!> \param prev_subsys ...
!> \par Used By
!>      fist_main
! **************************************************************************************************
   SUBROUTINE fist_init(fist_env, root_section, para_env, force_env_section, &
                        subsys_section, use_motion_section, prev_subsys)

      TYPE(fist_environment_type), POINTER               :: fist_env
      TYPE(section_vals_type), POINTER                   :: root_section
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(section_vals_type), POINTER                   :: force_env_section, subsys_section
      LOGICAL, INTENT(IN)                                :: use_motion_section
      TYPE(cp_subsys_type), OPTIONAL, POINTER            :: prev_subsys

      CHARACTER(len=*), PARAMETER                        :: routineN = 'fist_init'

      INTEGER                                            :: handle, iw
      LOGICAL                                            :: qmmm, shell_adiabatic, shell_present
      REAL(KIND=dp), DIMENSION(3)                        :: abc
      TYPE(cell_type), POINTER                           :: cell, cell_ref
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(ewald_environment_type), POINTER              :: ewald_env
      TYPE(exclusion_type), DIMENSION(:), POINTER        :: exclusions
      TYPE(fist_efield_type), POINTER                    :: efield
      TYPE(fist_nonbond_env_type), POINTER               :: fist_nonbond_env
      TYPE(particle_list_type), POINTER                  :: core_particles, shell_particles
      TYPE(particle_type), DIMENSION(:), POINTER         :: core_particle_set, shell_particle_set
      TYPE(qmmm_env_mm_type), POINTER                    :: qmmm_env
      TYPE(section_vals_type), POINTER                   :: cell_section, ewald_section, mm_section, &
                                                            poisson_section

      CALL timeset(routineN, handle)
      logger => cp_get_default_logger()

      NULLIFY (subsys, cell, cell_ref)
      NULLIFY (ewald_env, fist_nonbond_env, qmmm_env, cell_section, &
               poisson_section, shell_particle_set, shell_particles, &
               core_particle_set, core_particles, exclusions)
      IF (.NOT. ASSOCIATED(subsys_section)) THEN
         subsys_section => section_vals_get_subs_vals(force_env_section, "SUBSYS")
      END IF
      mm_section => section_vals_get_subs_vals(force_env_section, "MM")
      cell_section => section_vals_get_subs_vals(subsys_section, "CELL")
      poisson_section => section_vals_get_subs_vals(mm_section, "POISSON")
      ewald_section => section_vals_get_subs_vals(poisson_section, "EWALD")

      CALL fist_env_set(fist_env, input=force_env_section)

      iw = cp_print_key_unit_nr(logger, mm_section, "PRINT%PROGRAM_BANNER", &
                                extension=".mmLog")
      CALL fist_header(iw)
      CALL cp_print_key_finished_output(iw, logger, mm_section, "PRINT%PROGRAM_BANNER")

      CALL read_cell(cell, cell_ref, cell_section=cell_section, para_env=para_env)
      CALL get_cell(cell, abc=abc)

      ! Print the cell parameters
      CALL write_cell(cell, subsys_section, cell_ref)

      ! Create the ewald environment
      ALLOCATE (ewald_env)
      CALL ewald_env_create(ewald_env, para_env)

      ! Read the input section and set the ewald_env
      CALL read_ewald_section(ewald_env, ewald_section)
      CALL ewald_env_set(ewald_env, poisson_section=poisson_section)

      ! Read the efield section
      NULLIFY (efield)
      CALL read_efield_section(mm_section, efield)
      CALL fist_env_set(fist_env, efield=efield)

      ! Topology
      CALL fist_env_get(fist_env, qmmm=qmmm, qmmm_env=qmmm_env)
      CALL cp_subsys_create(subsys, para_env=para_env, root_section=root_section, &
                            force_env_section=force_env_section, subsys_section=subsys_section, &
                            qmmm=qmmm, qmmm_env=qmmm_env, exclusions=exclusions, &
                            use_motion_section=use_motion_section)
      CALL fist_env_set(fist_env, subsys=subsys, exclusions=exclusions)

      CALL force_field_control(subsys%atomic_kinds%els, subsys%particles%els, &
                               subsys%molecule_kinds%els, subsys%molecules%els, &
                               ewald_env, fist_nonbond_env, root_section, para_env, qmmm=qmmm, &
                               qmmm_env=qmmm_env, subsys_section=subsys_section, &
                               mm_section=mm_section, shell_particle_set=shell_particle_set, &
                               core_particle_set=core_particle_set, cell=cell)

      NULLIFY (shell_particles, core_particles)
      IF (ASSOCIATED(shell_particle_set)) THEN
         CALL cite_reference(Devynck2012)
         CALL cite_reference(Mitchell1993)
         CALL cite_reference(Dick1958)
         CALL particle_list_create(shell_particles, els_ptr=shell_particle_set)
      END IF
      IF (ASSOCIATED(core_particle_set)) THEN
         CALL particle_list_create(core_particles, els_ptr=core_particle_set)
      END IF
      CALL get_atomic_kind_set(atomic_kind_set=subsys%atomic_kinds%els, &
                               shell_present=shell_present, shell_adiabatic=shell_adiabatic)
      CALL fist_env_set(fist_env, shell_model=shell_present, &
                        shell_model_ad=shell_adiabatic)
      CALL cp_subsys_set(subsys, shell_particles=shell_particles, &
                         core_particles=core_particles)
      CALL particle_list_release(shell_particles)
      CALL particle_list_release(core_particles)

      CALL fist_init_subsys(fist_env, subsys, cell, cell_ref, fist_nonbond_env, ewald_env, &
                            force_env_section, subsys_section, prev_subsys)

      CALL cell_release(cell)
      CALL cell_release(cell_ref)

      CALL timestop(handle)

   END SUBROUTINE fist_init

! **************************************************************************************************
!> \brief   Read the input and the database files for the setup of the
!>          FIST environment.
!> \param fist_env ...
!> \param subsys ...
!> \param cell ...
!> \param cell_ref ...
!> \param fist_nonbond_env ...
!> \param ewald_env ...
!> \param force_env_section ...
!> \param subsys_section ...
!> \param prev_subsys ...
!> \date    22.05.2000
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE fist_init_subsys(fist_env, subsys, cell, cell_ref, fist_nonbond_env, &
                               ewald_env, force_env_section, subsys_section, &
                               prev_subsys)

      TYPE(fist_environment_type), POINTER               :: fist_env
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(cell_type), POINTER                           :: cell, cell_ref
      TYPE(fist_nonbond_env_type), POINTER               :: fist_nonbond_env
      TYPE(ewald_environment_type), POINTER              :: ewald_env
      TYPE(section_vals_type), POINTER                   :: force_env_section, subsys_section
      TYPE(cp_subsys_type), OPTIONAL, POINTER            :: prev_subsys

      CHARACTER(len=*), PARAMETER                        :: routineN = 'fist_init_subsys'

      INTEGER                                            :: handle, max_multipole
      LOGICAL                                            :: do_multipoles
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(distribution_1d_type), POINTER                :: local_molecules, local_particles, &
                                                            prev_local_molecules
      TYPE(ewald_pw_type), POINTER                       :: ewald_pw
      TYPE(fist_energy_type), POINTER                    :: thermo
      TYPE(molecule_kind_type), DIMENSION(:), POINTER    :: molecule_kind_set, prev_molecule_kind_set
      TYPE(molecule_type), DIMENSION(:), POINTER         :: molecule_set
      TYPE(multipole_type), POINTER                      :: multipoles
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(section_vals_type), POINTER                   :: grid_print_section

      CALL timeset(routineN, handle)
      NULLIFY (thermo, ewald_pw, local_molecules, local_particles, multipoles)
      particle_set => subsys%particles%els
      atomic_kind_set => subsys%atomic_kinds%els
      molecule_set => subsys%molecules%els
      molecule_kind_set => subsys%molecule_kinds%els

      IF (PRESENT(prev_subsys)) THEN
         prev_molecule_kind_set => prev_subsys%molecule_kinds%els
         prev_local_molecules => prev_subsys%local_molecules
      ELSE
         NULLIFY (prev_molecule_kind_set)
         NULLIFY (prev_local_molecules)
      END IF

      ! Create the fist_energy_type
      CALL allocate_fist_energy(thermo)

      ! Print the molecule kind set
      CALL write_molecule_kind_set(molecule_kind_set, subsys_section)

      ! Print the atomic coordinates
      CALL write_fist_particle_coordinates(particle_set, subsys_section, &
                                           fist_nonbond_env%charges)
      CALL write_particle_distances(particle_set, cell, subsys_section)
      CALL write_structure_data(particle_set, cell=cell, input_section=subsys_section)

      ! Print symmetry information
      CALL write_symmetry(particle_set, cell, subsys_section)

      ! Distribute molecules and atoms using the new data structures ***
      CALL distribute_molecules_1d(atomic_kind_set=atomic_kind_set, &
                                   particle_set=particle_set, &
                                   local_particles=local_particles, &
                                   molecule_kind_set=molecule_kind_set, &
                                   molecule_set=molecule_set, &
                                   local_molecules=local_molecules, &
                                   prev_molecule_kind_set=prev_molecule_kind_set, &
                                   prev_local_molecules=prev_local_molecules, &
                                   force_env_section=force_env_section)

      ! Create ewald grids
      grid_print_section => section_vals_get_subs_vals(force_env_section, &
                                                       "PRINT%GRID_INFORMATION")
      ALLOCATE (ewald_pw)
      CALL ewald_pw_create(ewald_pw, ewald_env, cell, cell_ref, grid_print_section)

      ! Initialize ewald grids
      CALL ewald_pw_grid_update(ewald_pw, ewald_env, cell%hmat)

      ! Possibly Initialize the multipole environment
      CALL ewald_env_get(ewald_env, do_multipoles=do_multipoles, &
                         max_multipole=max_multipole)
      IF (do_multipoles) THEN
         ALLOCATE (multipoles)
         CALL create_multipole_type(multipoles, particle_set, subsys_section, max_multipole)
      END IF
      CALL cp_subsys_set(subsys, multipoles=multipoles, cell=cell)

      ! Set the fist_env
      CALL fist_env_set(fist_env=fist_env, &
                        cell_ref=cell_ref, &
                        local_molecules=local_molecules, &
                        local_particles=local_particles, &
                        ewald_env=ewald_env, ewald_pw=ewald_pw, &
                        fist_nonbond_env=fist_nonbond_env, &
                        thermo=thermo)

      CALL distribution_1d_release(local_particles)
      CALL distribution_1d_release(local_molecules)
      CALL timestop(handle)

   END SUBROUTINE fist_init_subsys
END MODULE fist_environment
