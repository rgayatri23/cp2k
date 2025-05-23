!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief evaluete the potential energy and its gradients using an array
!>      with same dimension as the particle_set
!> \param gopt_env the geometry optimization environment
!> \param x the position where the function should be evaluated
!> \param f the function value
!> \param gradient the value of its gradient
!> \param master ...
!> \param final_evaluation ...
!> \param para_env ...
!> \par History
!>       CELL OPTIMIZATION:  Teodoro Laino [tlaino] - University of Zurich - 03.2008
!>       07.2020 Pierre Cazade [pcazade] Space Group Symmetry
!> \author Teodoro Laino [tlaino] - University of Zurich - 01.2008
! **************************************************************************************************
SUBROUTINE cp_eval_at(gopt_env, x, f, gradient, master, &
                      final_evaluation, para_env)

   USE cp_log_handling, ONLY: cp_logger_type
   USE averages_types, ONLY: average_quantities_type, &
                             create_averages, &
                             release_averages
   USE bibliography, ONLY: Henkelman1999, &
                           cite_reference
   USE cell_opt_utils, ONLY: get_dg_dh, &
                             gopt_new_logger_create, &
                             gopt_new_logger_release
   USE cell_types, ONLY: cell_type
   USE cell_methods, ONLY: write_cell
   USE cp_para_types, ONLY: cp_para_env_type
   USE cp_subsys_types, ONLY: cp_subsys_get, &
                              cp_subsys_type, &
                              pack_subsys_particles, &
                              unpack_subsys_particles
   USE dimer_methods, ONLY: cp_eval_at_ts
   USE force_env_methods, ONLY: force_env_calc_energy_force
   USE force_env_types, ONLY: force_env_get, &
                              force_env_get_nparticle
   USE geo_opt, ONLY: cp_geo_opt
   USE gopt_f_types, ONLY: gopt_f_type
   USE gopt_f_methods, ONLY: apply_cell_change
   USE input_constants, ONLY: default_minimization_method_id, &
                              default_ts_method_id, &
                              default_cell_direct_id, &
                              default_cell_method_id, &
                              default_cell_geo_opt_id, &
                              default_cell_md_id, &
                              default_shellcore_method_id, &
                              nvt_ensemble, &
                              mol_dyn_run, &
                              geo_opt_run, &
                              cell_opt_run, &
                              fix_none
   USE input_section_types, ONLY: section_vals_get, &
                                  section_vals_get_subs_vals, &
                                  section_vals_type, &
                                  section_vals_val_get
   USE md_run, ONLY: qs_mol_dyn
   USE message_passing, ONLY: mp_bcast
   USE kinds, ONLY: dp, &
                    default_string_length
   USE particle_list_types, ONLY: particle_list_type
   USE particle_methods, ONLY: write_structure_data
   USE virial_methods, ONLY: virial_update
   USE virial_types, ONLY: cp_virial, &
                           virial_type, zero_virial
   USE cp_log_handling, ONLY: cp_add_default_logger, &
                              cp_rm_default_logger
   USE space_groups_types, ONLY: spgr_type
   USE space_groups, ONLY: spgr_apply_rotations_stress, &
                           spgr_apply_rotations_coord, &
                           spgr_apply_rotations_force, &
                           spgr_write_stress_tensor

#include "../base/base_uses.f90"
   IMPLICIT NONE
   TYPE(gopt_f_type), POINTER               :: gopt_env
   REAL(KIND=dp), DIMENSION(:), POINTER     :: x
   REAL(KIND=dp), INTENT(OUT), OPTIONAL     :: f
   REAL(KIND=dp), DIMENSION(:), OPTIONAL, &
      POINTER                                :: gradient
   INTEGER, INTENT(IN)                      :: master
   LOGICAL, INTENT(IN), OPTIONAL            :: final_evaluation
   TYPE(cp_para_env_type), POINTER          :: para_env

   CHARACTER(len=*), PARAMETER :: routineN = 'cp_eval_at'

   INTEGER                                  :: ensemble, handle, idg, idir, ip, &
                                               nparticle, nsize, shell_index
   LOGICAL                                  :: explicit, my_final_evaluation
   REAL(KIND=dp)                            :: f_ts, potential_energy
   REAL(KIND=dp), DIMENSION(3, 3)           :: av_ptens
   REAL(KIND=dp), DIMENSION(:), POINTER     :: cell_gradient, gradient_ts
   TYPE(cell_type), POINTER                 :: cell
   TYPE(cp_subsys_type), POINTER            :: subsys
   TYPE(particle_list_type), POINTER        :: core_particles, particles, &
                                               shell_particles
   TYPE(virial_type), POINTER               :: virial
   TYPE(cp_logger_type), POINTER            :: new_logger
   CHARACTER(LEN=default_string_length)     :: project_name
   TYPE(average_quantities_type), POINTER   :: averages
   TYPE(section_vals_type), POINTER         :: work, avgs_section
   TYPE(spgr_type), POINTER                 :: spgr

   NULLIFY (averages)
   NULLIFY (cell)
   NULLIFY (core_particles)
   NULLIFY (gradient_ts)
   NULLIFY (particles)
   NULLIFY (shell_particles)
   NULLIFY (subsys)
   NULLIFY (virial)
   NULLIFY (new_logger)
   NULLIFY (spgr)

   CALL timeset(routineN, handle)

   CALL force_env_get(gopt_env%force_env, subsys=subsys, cell=cell)
   CALL cp_subsys_get(subsys, &
                      core_particles=core_particles, &
                      particles=particles, &
                      shell_particles=shell_particles, &
                      virial=virial)

   spgr => gopt_env%spgr

   my_final_evaluation = .FALSE.
   IF (PRESENT(final_evaluation)) my_final_evaluation = final_evaluation

   SELECT CASE (gopt_env%type_id)
   CASE (default_minimization_method_id, default_ts_method_id)
      CALL unpack_subsys_particles(subsys=subsys, r=x)
      CALL write_structure_data(particles%els, cell, gopt_env%motion_section)
      SELECT CASE (gopt_env%type_id)
      CASE (default_minimization_method_id)
         ! Geometry Minimization
         CALL force_env_calc_energy_force(gopt_env%force_env, &
                                          calc_force=PRESENT(gradient), &
                                          require_consistent_energy_force=gopt_env%require_consistent_energy_force)
         ! Possibly take the potential energy
         IF (PRESENT(f)) THEN
            CALL force_env_get(gopt_env%force_env, potential_energy=f)
         END IF
         ! Possibly take the gradients
         IF (PRESENT(gradient)) THEN
            IF (master == para_env%mepos) THEN ! we are on the master
               CALL pack_subsys_particles(subsys=subsys, f=gradient, fscale=-1.0_dp)
               IF (spgr%keep_space_group) THEN
                  CALL spgr_apply_rotations_force(spgr, gradient)
                  CALL unpack_subsys_particles(subsys=subsys, f=gradient, fscale=-1.0_dp)
               END IF
            END IF
         END IF
      CASE (default_ts_method_id)
         ! Transition State Optimization
         ALLOCATE (gradient_ts(particles%n_els*3))
         ! Real calculation of energy and forces for transition state optimization:
         ! When doing dimer methods forces have to be always computed since the function
         ! to minimize is not the energy but the effective force
         CALL cp_eval_at_ts(gopt_env, x, f_ts, gradient_ts, calc_force=.TRUE.)
         CALL cite_reference(Henkelman1999)
         ! Possibly take the potential energy
         IF (PRESENT(f)) f = f_ts
         ! Possibly take the gradients
         IF (PRESENT(gradient)) THEN
            IF (master == para_env%mepos) THEN ! we are on the master
               CPASSERT(ASSOCIATED(gradient))
               gradient = gradient_ts
            END IF
         END IF
         DEALLOCATE (gradient_ts)
      END SELECT
      ! This call is necessary for QM/MM if a Translation is applied
      ! this makes the geometry optimizer consistent
      CALL unpack_subsys_particles(subsys=subsys, r=x)
   CASE (default_cell_method_id)
      ! Check for VIRIAL
      IF (.NOT. virial%pv_availability) &
         CALL cp_abort(__LOCATION__, &
                       "Cell optimization requested but FORCE_EVAL%STRESS_TENSOR was not defined! "// &
                       "Activate the evaluation of the stress tensor for cell optimization!")
      SELECT CASE (gopt_env%cell_method_id)
      CASE (default_cell_direct_id)
         CALL apply_cell_change(gopt_env, cell, x, update_forces=.FALSE.)
         ! Possibly output the new cell used for the next calculation
         CALL write_cell(cell, gopt_env%geo_section)
         ! Compute the pressure tensor
         BLOCK
            TYPE(virial_type) :: virial_avg
            CALL zero_virial(virial_avg)
            CALL force_env_calc_energy_force(gopt_env%force_env, &
                                             calc_force=PRESENT(gradient), &
                                             require_consistent_energy_force=gopt_env%require_consistent_energy_force)
            ! Possibly take the potential energy
            CALL force_env_get(gopt_env%force_env, potential_energy=potential_energy)
            CALL cp_virial(virial, virial_avg)
            CALL virial_update(virial_avg, subsys, para_env)
            IF (PRESENT(f)) THEN
               CALL force_env_get(gopt_env%force_env, potential_energy=f)
            END IF
            ! Possibly take the gradients
            IF (PRESENT(gradient)) THEN
               CPASSERT(ANY(virial_avg%pv_total /= 0))
               ! Convert the average ptens
               av_ptens(:, :) = virial_avg%pv_total(:, :)/cell%deth
               IF (master == para_env%mepos) THEN ! we are on the master
                  CPASSERT(ASSOCIATED(gradient))
                  nparticle = force_env_get_nparticle(gopt_env%force_env)
                  nsize = 3*nparticle
                  CPASSERT((SIZE(gradient) == nsize + 6))
                  CALL pack_subsys_particles(subsys=subsys, f=gradient(1:nsize), fscale=-1.0_dp)
                  CALL apply_cell_change(gopt_env, cell, gradient, update_forces=.TRUE.)
                  IF (spgr%keep_space_group) THEN
                     CALL spgr_apply_rotations_force(spgr, gradient)
                     CALL spgr_apply_rotations_stress(spgr, cell, av_ptens)
                     CALL spgr_write_stress_tensor(av_ptens, spgr)
                  END IF
                  cell_gradient => gradient(nsize + 1:nsize + 6)
                  cell_gradient = 0.0_dp
                  CALL get_dg_dh(cell_gradient, av_ptens, gopt_env%cell_env%pres_ext, cell, gopt_env%cell_env%mtrx, &
                                 keep_angles=gopt_env%cell_env%keep_angles, &
                                 keep_symmetry=gopt_env%cell_env%keep_symmetry, &
                                 pres_int=gopt_env%cell_env%pres_int, &
                                 pres_constr=gopt_env%cell_env%pres_constr, &
                                 constraint_id=gopt_env%cell_env%constraint_id)
               END IF
               ! some callers expect pres_int to be available on all ranks. Also, here master is not necessarily a single rank.
               ! Assume at least master==0
               CALL mp_bcast(gopt_env%cell_env%pres_int, 0, para_env%group)
               IF (gopt_env%cell_env%constraint_id /= fix_none) &
                  CALL mp_bcast(gopt_env%cell_env%pres_constr, 0, para_env%group)
            END IF
         END BLOCK
      CASE (default_cell_geo_opt_id, default_cell_md_id)
         CALL apply_cell_change(gopt_env, cell, x, update_forces=.FALSE.)
         ! Possibly output the new cell used for the next calculation
         CALL write_cell(cell, gopt_env%geo_section)
         ! Compute the pressure tensor
         BLOCK
            TYPE(virial_type) :: virial_avg
            CALL zero_virial(virial_avg)
            IF (my_final_evaluation) THEN
               CALL force_env_calc_energy_force(gopt_env%force_env, &
                                                calc_force=PRESENT(gradient), &
                                                require_consistent_energy_force=gopt_env%require_consistent_energy_force)
               IF (PRESENT(f)) THEN
                  CALL force_env_get(gopt_env%force_env, potential_energy=f)
               END IF
            ELSE
               SELECT CASE (gopt_env%cell_method_id)
               CASE (default_cell_geo_opt_id)
                  work => section_vals_get_subs_vals(gopt_env%motion_section, "GEO_OPT")
                  CALL section_vals_get(work, explicit=explicit)
                  IF (.NOT. explicit) &
                     CALL cp_abort(__LOCATION__, &
                                   "Cell optimization at 0K was requested. GEO_OPT section MUST be provided in the input file!")
                  ! Perform a geometry optimization
                  CALL gopt_new_logger_create(new_logger, gopt_env%force_env%root_section, para_env, &
                                              project_name, id_run=geo_opt_run)
                  CALL cp_add_default_logger(new_logger)
                  CALL cp_geo_opt(gopt_env%force_env, gopt_env%globenv, eval_opt_geo=.FALSE.)
                  CALL force_env_get(gopt_env%force_env, potential_energy=potential_energy)
                  CALL cp_virial(virial, virial_avg)
               CASE (default_cell_md_id)
                  work => section_vals_get_subs_vals(gopt_env%motion_section, "MD")
                  avgs_section => section_vals_get_subs_vals(work, "AVERAGES")
                  CALL section_vals_get(work, explicit=explicit)
                  IF (.NOT. explicit) &
                     CALL cp_abort( &
                     __LOCATION__, &
                     "Cell optimization at finite temperature was requested. MD section MUST be provided in the input file!")
                  ! Only NVT ensemble is allowed..
                  CALL section_vals_val_get(gopt_env%motion_section, "MD%ENSEMBLE", i_val=ensemble)
                  IF (ensemble /= nvt_ensemble) &
                     CALL cp_abort(__LOCATION__, &
                                   "Cell optimization at finite temperature requires the NVT MD ensemble!")
                  ! Perform a molecular dynamics
                  CALL gopt_new_logger_create(new_logger, gopt_env%force_env%root_section, para_env, &
                                              project_name, id_run=mol_dyn_run)
                  CALL cp_add_default_logger(new_logger)
                  CALL create_averages(averages, avgs_section, virial_avg=.TRUE., force_env=gopt_env%force_env)
                  CALL qs_mol_dyn(gopt_env%force_env, gopt_env%globenv, averages, rm_restart_info=.FALSE.)
                  ! Retrieve the average of the stress tensor and the average of the potential energy
                  potential_energy = averages%avepot
                  CALL cp_virial(averages%virial, virial_avg)
                  CALL release_averages(averages)
               CASE DEFAULT
                  CPABORT("")
               END SELECT
               CALL cp_rm_default_logger()
               CALL gopt_new_logger_release(new_logger, gopt_env%force_env%root_section, para_env, project_name, &
                                            cell_opt_run)
               ! Update the virial
               CALL virial_update(virial_avg, subsys, para_env)
               ! Possibly take give back the potential energy
               IF (PRESENT(f)) THEN
                  f = potential_energy
               END IF
            END IF
            ! Possibly give back the gradients
            IF (PRESENT(gradient)) THEN
               CPASSERT(ANY(virial_avg%pv_total /= 0))
               ! Convert the average ptens
               av_ptens(:, :) = virial_avg%pv_total(:, :)/cell%deth
               IF (master == para_env%mepos) THEN ! we are on the master
                  CPASSERT(ASSOCIATED(gradient))
                  IF (spgr%keep_space_group) THEN
                     CALL spgr_apply_rotations_stress(spgr, cell, av_ptens)
                     CALL spgr_write_stress_tensor(av_ptens, spgr)
                  END IF
                  ! Compute the gradients on the cell
                  CALL get_dg_dh(gradient, av_ptens, gopt_env%cell_env%pres_ext, cell, gopt_env%cell_env%mtrx, &
                                 keep_angles=gopt_env%cell_env%keep_angles, &
                                 keep_symmetry=gopt_env%cell_env%keep_symmetry, &
                                 pres_int=gopt_env%cell_env%pres_int, &
                                 pres_constr=gopt_env%cell_env%pres_constr, &
                                 constraint_id=gopt_env%cell_env%constraint_id)
               END IF
               ! some callers expect pres_int to be available on all ranks. Also, here master is not necessarily a single rank.
               ! Assume at least master==0
               CALL mp_bcast(gopt_env%cell_env%pres_int, 0, para_env%group)
               IF (gopt_env%cell_env%constraint_id /= fix_none) &
                  CALL mp_bcast(gopt_env%cell_env%pres_constr, 0, para_env%group)
            END IF
         END BLOCK
      CASE DEFAULT
         CPABORT("")
      END SELECT
   CASE (default_shellcore_method_id)
      idg = 0
      DO ip = 1, particles%n_els
         shell_index = particles%els(ip)%shell_index
         IF (shell_index /= 0) THEN
            DO idir = 1, 3
               idg = 3*(shell_index - 1) + idir
               shell_particles%els(shell_index)%r(idir) = core_particles%els(ip)%r(idir) - x(idg)
            END DO
         END IF
      END DO
      CALL write_structure_data(particles%els, cell, gopt_env%motion_section)

      ! Shell-core optimization
      CALL force_env_calc_energy_force(gopt_env%force_env, &
                                       calc_force=PRESENT(gradient), &
                                       require_consistent_energy_force=gopt_env%require_consistent_energy_force)

      ! Possibly take the potential energy
      IF (PRESENT(f)) THEN
         CALL force_env_get(gopt_env%force_env, potential_energy=f)
      END IF

      ! Possibly take the gradients
      IF (PRESENT(gradient)) THEN
         IF (master == para_env%mepos) THEN ! we are on the master
            CPASSERT(ASSOCIATED(gradient))
            idg = 0
            DO ip = 1, shell_particles%n_els
               DO idir = 1, 3
                  idg = idg + 1
                  gradient(idg) = -(core_particles%els(ip)%f(idir) - shell_particles%els(ip)%f(idir))
               END DO
            END DO
         END IF
      END IF
   CASE DEFAULT
      CPABORT("")
   END SELECT

   CALL timestop(handle)

END SUBROUTINE cp_eval_at
