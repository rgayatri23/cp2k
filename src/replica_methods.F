!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief methods to setup replicas of the same system differing only by atom
!>      positions and velocities (as used in path integral or nudged elastic
!>      band for example)
!> \par History
!>      09.2005 created [fawzi]
!> \author fawzi
! **************************************************************************************************
MODULE replica_methods
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_io_unit,&
                                              cp_logger_type,&
                                              cp_to_string
   USE cp_output_handling,              ONLY: cp_add_iter_level
   USE cp_para_env,                     ONLY: cp_cart_create,&
                                              cp_para_env_create
   USE cp_para_types,                   ONLY: cp_para_cart_type,&
                                              cp_para_env_type
   USE cp_result_types,                 ONLY: cp_result_create,&
                                              cp_result_retain
   USE cp_subsys_types,                 ONLY: cp_subsys_get,&
                                              cp_subsys_set,&
                                              cp_subsys_type
   USE f77_interface,                   ONLY: calc_force,&
                                              create_force_env,&
                                              f_env_add_defaults,&
                                              f_env_rm_defaults,&
                                              f_env_type,&
                                              get_nparticle,&
                                              get_pos,&
                                              set_vel
   USE force_env_types,                 ONLY: force_env_get,&
                                              use_qs_force
   USE input_section_types,             ONLY: section_type,&
                                              section_vals_type,&
                                              section_vals_val_get,&
                                              section_vals_val_set,&
                                              section_vals_write
   USE kinds,                           ONLY: default_path_length,&
                                              dp
   USE message_passing,                 ONLY: mp_cart_create,&
                                              mp_cart_sub,&
                                              mp_comm_null,&
                                              mp_comm_type,&
                                              mp_sum
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type,&
                                              set_qs_env
   USE qs_wf_history_methods,           ONLY: wfi_create,&
                                              wfi_create_for_kp
   USE qs_wf_history_types,             ONLY: wfi_retain
   USE replica_types,                   ONLY: rep_env_sync,&
                                              rep_env_sync_results,&
                                              rep_envs_add_rep_env,&
                                              rep_envs_get_rep_env,&
                                              replica_env_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'replica_methods'
   INTEGER, SAVE, PRIVATE :: last_rep_env_id = 0

   PUBLIC :: rep_env_create, rep_env_calc_e_f

CONTAINS

! **************************************************************************************************
!> \brief creates a replica environment together with its force environment
!> \param rep_env the replica environment that will be created
!> \param para_env the parallel environment that will contain the replicas
!> \param input the input used to initialize the force environment
!> \param input_declaration ...
!> \param nrep the number of replicas to calculate
!> \param prep the number of processors for each replica
!> \param sync_v if the velocity should be synchronized (defaults to false)
!> \param keep_wf_history if wf history should be kept on a per replica
!>        basis (defaults to true for QS jobs)
!> \param row_force to use the new mapping to the cart with rows
!>        working on force instead of columns.
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE rep_env_create(rep_env, para_env, input, input_declaration, nrep, prep, &
                             sync_v, keep_wf_history, row_force)
      TYPE(replica_env_type), POINTER                    :: rep_env
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(section_vals_type), POINTER                   :: input
      TYPE(section_type), POINTER                        :: input_declaration
      INTEGER                                            :: nrep, prep
      LOGICAL, INTENT(in), OPTIONAL                      :: sync_v, keep_wf_history, row_force

      CHARACTER(len=default_path_length)                 :: input_file_path, output_file_path
      INTEGER                                            :: forcedim, i, i0, ierr, ip, ir, irep, lp, &
                                                            my_prep, new_env_id, nparticle, &
                                                            nrep_local, unit_nr
      INTEGER, ALLOCATABLE, DIMENSION(:, :)              :: gridinfo
      INTEGER, DIMENSION(2)                              :: dims, pos
      LOGICAL, DIMENSION(2)                              :: rdim
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_para_cart_type), POINTER                   :: cart
      TYPE(cp_para_env_type), POINTER                    :: para_env_f, para_env_full, &
                                                            para_env_inter_rep
      TYPE(mp_comm_type)                                 :: comm_cart, comm_f, comm_inter_rep

      CPASSERT(.NOT. ASSOCIATED(rep_env))
      CPASSERT(ASSOCIATED(input_declaration))

      NULLIFY (cart, para_env_f, para_env_inter_rep)
      logger => cp_get_default_logger()
      unit_nr = cp_logger_get_default_io_unit(logger)
      new_env_id = -1
      forcedim = 1
      IF (PRESENT(row_force)) THEN
         IF (row_force) forcedim = 2
      END IF
      my_prep = MIN(prep, para_env%num_pe)
      dims(3 - forcedim) = MIN(para_env%num_pe/my_prep, nrep)
      dims(forcedim) = my_prep
      IF ((dims(1)*dims(2) /= para_env%num_pe) .AND. (unit_nr > 0)) THEN
         WRITE (unit_nr, FMT="(T2,A)") "REPLICA| WARNING: number of processors is not divisible by the number of replicas"
         WRITE (unit_nr, FMT="(T2,A,I0,A)") "REPLICA| ", para_env%num_pe - dims(1)*dims(2), " MPI process(es) will be idle"
      END IF
      CALL mp_cart_create(comm_old=para_env%group, ndims=2, dims=dims, pos=pos, comm_cart=comm_cart)
      IF (comm_cart /= mp_comm_null) THEN
         CALL cp_cart_create(cart, comm_cart, ndims=2, owns_group=.TRUE.)
         NULLIFY (para_env_full)
         CALL cp_para_env_create(para_env_full, comm_cart, owns_group=.FALSE.)
         rdim(3 - forcedim) = .FALSE.
         rdim(forcedim) = .TRUE.
         CALL mp_cart_sub(comm=comm_cart, rdim=rdim, sub_comm=comm_f)
         CALL cp_para_env_create(para_env_f, comm_f, owns_group=.TRUE.)
         rdim(3 - forcedim) = .TRUE.
         rdim(forcedim) = .FALSE.
         CALL mp_cart_sub(comm=comm_cart, rdim=rdim, sub_comm=comm_inter_rep)
         CALL cp_para_env_create(para_env_inter_rep, comm_inter_rep, &
                                 owns_group=.TRUE.)
         ALLOCATE (rep_env)
      END IF
      ALLOCATE (gridinfo(2, 0:para_env%num_pe - 1))
      gridinfo = 0
      gridinfo(:, para_env%mepos) = pos
      CALL mp_sum(gridinfo, para_env%group)
      IF (unit_nr > 0) THEN
         WRITE (unit_nr, FMT="(T2,A,T71,I10)") "REPLICA| layout of the replica grid, number of groups ", para_env_inter_rep%num_pe
         WRITE (unit_nr, FMT="(T2,A,T71,I10)") "REPLICA| layout of the replica grid, size of each group", para_env_f%num_pe
         WRITE (unit_nr, FMT="(T2,A)", ADVANCE="NO") "REPLICA| MPI process to grid (group,rank) correspondence:"
         DO i = 0, para_env%num_pe - 1
            IF (MODULO(i, 4) == 0) WRITE (unit_nr, *)
            WRITE (unit_nr, FMT='(A3,I4,A3,I4,A1,I4,A1)', ADVANCE="NO") &
               "  (", i, " : ", gridinfo(3 - forcedim, i), ",", &
               gridinfo(forcedim, i), ")"
         END DO
         WRITE (unit_nr, *)
      END IF
      DEALLOCATE (gridinfo)
      IF (ASSOCIATED(rep_env)) THEN
         last_rep_env_id = last_rep_env_id + 1
         rep_env%id_nr = last_rep_env_id
         rep_env%ref_count = 1
         rep_env%nrep = nrep
         rep_env%sync_v = .FALSE.
         IF (PRESENT(sync_v)) rep_env%sync_v = sync_v
         rep_env%keep_wf_history = .TRUE.
         IF (PRESENT(keep_wf_history)) rep_env%keep_wf_history = keep_wf_history
         NULLIFY (rep_env%wf_history)
         NULLIFY (rep_env%results)

         rep_env%force_dim = forcedim
         rep_env%my_rep_group = cart%mepos(3 - forcedim)
         ALLOCATE (rep_env%inter_rep_rank(0:para_env_inter_rep%num_pe - 1), &
                   rep_env%force_rank(0:para_env_f%num_pe - 1))
         rep_env%inter_rep_rank = 0
         rep_env%inter_rep_rank(rep_env%my_rep_group) = para_env_inter_rep%mepos
         CALL mp_sum(rep_env%inter_rep_rank, para_env_inter_rep%group)
         rep_env%force_rank = 0
         rep_env%force_rank(cart%mepos(forcedim)) = para_env_f%mepos
         CALL mp_sum(rep_env%force_rank, para_env_f%group)

         CALL section_vals_val_get(input, "GLOBAL%PROJECT_NAME", &
                                   c_val=input_file_path)
         rep_env%original_project_name = input_file_path
         ! By default replica_env handles files for each replica
         ! with the structure PROJECT_NAME-r-N where N is the
         ! number of the local replica..
         lp = LEN_TRIM(input_file_path)
         input_file_path(lp + 1:LEN(input_file_path)) = "-r-"// &
                                                        ADJUSTL(cp_to_string(rep_env%my_rep_group))
         lp = LEN_TRIM(input_file_path)
         ! Setup new project name
         CALL section_vals_val_set(input, "GLOBAL%PROJECT_NAME", &
                                   c_val=input_file_path)
         ! Redirect the output of each replica on a same local file
         output_file_path = input_file_path(1:lp)//".out"
         CALL section_vals_val_set(input, "GLOBAL%OUTPUT_FILE_NAME", &
                                   c_val=TRIM(output_file_path))

         ! Dump an input file to warm-up new force_eval structures and
         ! delete them immediately afterwards..
         input_file_path(lp + 1:LEN(input_file_path)) = ".inp"
         IF (para_env_f%ionode) THEN
            CALL open_file(file_name=TRIM(input_file_path), file_status="UNKNOWN", &
                           file_form="FORMATTED", file_action="WRITE", &
                           unit_number=unit_nr)
            CALL section_vals_write(input, unit_nr, hide_root=.TRUE.)
            CALL close_file(unit_nr)
         END IF
         CALL create_force_env(new_env_id, input_declaration, input_file_path, &
                               output_file_path, para_env_f%group, ierr=ierr)
         CPASSERT(ierr == 0)

         ! Delete input files..
         IF (para_env_f%ionode) THEN
            CALL open_file(file_name=TRIM(input_file_path), file_status="OLD", &
                           file_form="FORMATTED", file_action="READ", unit_number=unit_nr)
            CALL close_file(unit_number=unit_nr, file_status="DELETE")
         END IF

         rep_env%f_env_id = new_env_id
         CALL get_nparticle(new_env_id, nparticle, ierr)
         CPASSERT(ierr == 0)
         rep_env%nparticle = nparticle
         rep_env%ndim = 3*nparticle
         ALLOCATE (rep_env%replica_owner(nrep))

         i0 = nrep/para_env_inter_rep%num_pe
         ir = MODULO(nrep, para_env_inter_rep%num_pe)
         DO ip = 0, para_env_inter_rep%num_pe - 1
            DO i = i0*ip + MIN(ip, ir) + 1, i0*(ip + 1) + MIN(ip + 1, ir)
               rep_env%replica_owner(i) = ip
            END DO
         END DO

         nrep_local = i0
         IF (rep_env%my_rep_group < ir) nrep_local = nrep_local + 1
         ALLOCATE (rep_env%local_rep_indices(nrep_local), &
                   rep_env%rep_is_local(nrep))
         nrep_local = 0
         rep_env%rep_is_local = .FALSE.
         DO irep = 1, nrep
            IF (rep_env%replica_owner(irep) == rep_env%my_rep_group) THEN
               nrep_local = nrep_local + 1
               rep_env%local_rep_indices(nrep_local) = irep
               rep_env%rep_is_local(irep) = .TRUE.
            END IF
         END DO
         CPASSERT(nrep_local == SIZE(rep_env%local_rep_indices))

         rep_env%cart => cart
         rep_env%para_env => para_env_full
         rep_env%para_env_f => para_env_f
         rep_env%para_env_inter_rep => para_env_inter_rep

         ALLOCATE (rep_env%r(rep_env%ndim, nrep), rep_env%v(rep_env%ndim, nrep), &
                   rep_env%f(rep_env%ndim + 1, nrep))

         rep_env%r = 0._dp
         rep_env%f = 0._dp
         rep_env%v = 0._dp
         CALL set_vel(rep_env%f_env_id, rep_env%v(:, 1), rep_env%ndim, ierr)
         CPASSERT(ierr == 0)
         DO i = 1, nrep
            IF (rep_env%rep_is_local(i)) THEN
               CALL get_pos(rep_env%f_env_id, rep_env%r(:, i), rep_env%ndim, ierr)
               CPASSERT(ierr == 0)
            END IF
         END DO
      END IF
      IF (ASSOCIATED(rep_env)) THEN
         CALL rep_envs_add_rep_env(rep_env)
         CALL rep_env_init_low(rep_env%id_nr, ierr)
         CPASSERT(ierr == 0)
      END IF
   END SUBROUTINE rep_env_create

! **************************************************************************************************
!> \brief finishes the low level initialization of the replica env
!> \param rep_env_id id_nr of the replica environment that should be initialized
!> \param ierr will be non zero if there is an initialization error
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE rep_env_init_low(rep_env_id, ierr)
      INTEGER, INTENT(in)                                :: rep_env_id
      INTEGER, INTENT(out)                               :: ierr

      INTEGER                                            :: i, in_use, stat
      LOGICAL                                            :: do_kpoints, has_unit_metric
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(f_env_type), POINTER                          :: f_env
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(replica_env_type), POINTER                    :: rep_env

      rep_env => rep_envs_get_rep_env(rep_env_id, ierr=stat)
      IF (.NOT. ASSOCIATED(rep_env)) &
         CPABORT("could not find rep_env with id_nr"//cp_to_string(rep_env_id))
      NULLIFY (qs_env, dft_control, subsys)
      CALL f_env_add_defaults(f_env_id=rep_env%f_env_id, f_env=f_env)
      logger => cp_get_default_logger()
      logger%iter_info%iteration(1) = rep_env%my_rep_group
      CALL cp_add_iter_level(iteration_info=logger%iter_info, &
                             level_name="REPLICA_EVAL")
      !wf interp
      IF (rep_env%keep_wf_history) THEN
         CALL force_env_get(f_env%force_env, in_use=in_use)
         IF (in_use == use_qs_force) THEN
            CALL force_env_get(f_env%force_env, qs_env=qs_env)
            CALL get_qs_env(qs_env, dft_control=dft_control)
            ALLOCATE (rep_env%wf_history(SIZE(rep_env%local_rep_indices)))
            DO i = 1, SIZE(rep_env%wf_history)
               NULLIFY (rep_env%wf_history(i)%wf_history)
               IF (i == 1) THEN
                  CALL get_qs_env(qs_env, &
                                  wf_history=rep_env%wf_history(i)%wf_history)
                  CALL wfi_retain(rep_env%wf_history(i)%wf_history)
               ELSE
                  CALL get_qs_env(qs_env, has_unit_metric=has_unit_metric, &
                                  do_kpoints=do_kpoints)
                  CALL wfi_create(rep_env%wf_history(i)%wf_history, &
                                  interpolation_method_nr= &
                                  dft_control%qs_control%wf_interpolation_method_nr, &
                                  extrapolation_order=dft_control%qs_control%wf_extrapolation_order, &
                                  has_unit_metric=has_unit_metric)
                  IF (do_kpoints) THEN
                     CALL wfi_create_for_kp(rep_env%wf_history(i)%wf_history)
                  END IF
               END IF
            END DO
         ELSE
            rep_env%keep_wf_history = .FALSE.
         END IF
      END IF
      ALLOCATE (rep_env%results(rep_env%nrep))
      DO i = 1, rep_env%nrep
         NULLIFY (rep_env%results(i)%results)
         IF (i == 1) THEN
            CALL force_env_get(f_env%force_env, subsys=subsys)
            CALL cp_subsys_get(subsys, results=rep_env%results(i)%results)
            CALL cp_result_retain(rep_env%results(i)%results)
         ELSE
            CALL cp_result_create(rep_env%results(i)%results)
         END IF
      END DO
      CALL rep_env_sync(rep_env, rep_env%r)
      CALL rep_env_sync(rep_env, rep_env%v)
      CALL rep_env_sync(rep_env, rep_env%f)

      CALL f_env_rm_defaults(f_env, ierr)
      CPASSERT(ierr == 0)
   END SUBROUTINE rep_env_init_low

! **************************************************************************************************
!> \brief evaluates the forces
!> \param rep_env the replica environment on which you want to evaluate the
!>        forces
!> \param calc_f if true calculates also the forces, if false only the
!>        energy
!> \author fawzi
!> \note
!>      indirect through f77_int_low to work around fortran madness
! **************************************************************************************************
   SUBROUTINE rep_env_calc_e_f(rep_env, calc_f)
      TYPE(replica_env_type), POINTER                    :: rep_env
      LOGICAL, OPTIONAL                                  :: calc_f

      CHARACTER(len=*), PARAMETER                        :: routineN = 'rep_env_calc_e_f'

      INTEGER                                            :: handle, ierr, my_calc_f

      CALL timeset(routineN, handle)
      CPASSERT(ASSOCIATED(rep_env))
      CPASSERT(rep_env%ref_count > 0)
      my_calc_f = 0
      IF (PRESENT(calc_f)) THEN
         IF (calc_f) my_calc_f = 1
      END IF
      CALL rep_env_calc_e_f_low(rep_env%id_nr, my_calc_f, ierr)
      CPASSERT(ierr == 0)
      CALL timestop(handle)
   END SUBROUTINE rep_env_calc_e_f

! **************************************************************************************************
!> \brief calculates energy and force, internal private method
!> \param rep_env_id the id if the replica environment in which energy and
!>        forces have to be evaluated
!> \param calc_f if nonzero calculates also the forces along with the
!>        energy
!> \param ierr if an error happens this will be nonzero
!> \author fawzi
!> \note
!>      low level wrapper to export this function in f77_int_low and work
!>      around the handling of circular dependencies in fortran
! **************************************************************************************************
   RECURSIVE SUBROUTINE rep_env_calc_e_f_low(rep_env_id, calc_f, ierr)
      INTEGER, INTENT(in)                                :: rep_env_id, calc_f
      INTEGER, INTENT(out)                               :: ierr

      TYPE(f_env_type), POINTER                          :: f_env
      TYPE(replica_env_type), POINTER                    :: rep_env

      rep_env => rep_envs_get_rep_env(rep_env_id, ierr)
      IF (ASSOCIATED(rep_env)) THEN
         CALL f_env_add_defaults(f_env_id=rep_env%f_env_id, f_env=f_env)
         CALL rep_env_calc_e_f_int(rep_env, calc_f /= 0)
         CALL f_env_rm_defaults(f_env, ierr)
      ELSE
         ierr = 111
      END IF
   END SUBROUTINE rep_env_calc_e_f_low

! **************************************************************************************************
!> \brief calculates energy and force, internal private method
!> \param rep_env the replica env to update
!> \param calc_f if the force should be calculated as well (defaults to true)
!> \author fawzi
!> \note
!>      this is the where the real work is done
! **************************************************************************************************
   SUBROUTINE rep_env_calc_e_f_int(rep_env, calc_f)
      TYPE(replica_env_type), POINTER                    :: rep_env
      LOGICAL, OPTIONAL                                  :: calc_f

      INTEGER                                            :: i, ierr, irep, md_iter, my_calc_f, ndim
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_subsys_type), POINTER                      :: subsys
      TYPE(f_env_type), POINTER                          :: f_env
      TYPE(qs_environment_type), POINTER                 :: qs_env

      NULLIFY (f_env, qs_env, subsys)
      CPASSERT(ASSOCIATED(rep_env))
      CPASSERT(rep_env%ref_count > 0)
      my_calc_f = 3*rep_env%nparticle
      IF (PRESENT(calc_f)) THEN
         IF (.NOT. calc_f) my_calc_f = 0
      END IF

      CALL f_env_add_defaults(f_env_id=rep_env%f_env_id, f_env=f_env)
      logger => cp_get_default_logger()
      !     md_iter=logger%iter_info%iteration(2)+1
      md_iter = logger%iter_info%iteration(2)
      CALL f_env_rm_defaults(f_env, ierr)
      CPASSERT(ierr == 0)
      DO i = 1, SIZE(rep_env%local_rep_indices)
         irep = rep_env%local_rep_indices(i)
         ndim = 3*rep_env%nparticle
         IF (rep_env%sync_v) THEN
            CALL set_vel(rep_env%f_env_id, rep_env%v(:, irep), ndim, ierr)
            CPASSERT(ierr == 0)
         END IF

         logger%iter_info%iteration(1) = irep
         logger%iter_info%iteration(2) = md_iter

         IF (rep_env%keep_wf_history) THEN
            CALL f_env_add_defaults(f_env_id=rep_env%f_env_id, f_env=f_env)
            CALL force_env_get(f_env%force_env, qs_env=qs_env)
            CALL set_qs_env(qs_env, &
                            wf_history=rep_env%wf_history(i)%wf_history)
            CALL f_env_rm_defaults(f_env, ierr)
            CPASSERT(ierr == 0)
         END IF

         CALL f_env_add_defaults(f_env_id=rep_env%f_env_id, f_env=f_env)
         CALL force_env_get(f_env%force_env, subsys=subsys)
         CALL cp_subsys_set(subsys, results=rep_env%results(irep)%results)
         CALL f_env_rm_defaults(f_env, ierr)
         CPASSERT(ierr == 0)
         CALL calc_force(rep_env%f_env_id, rep_env%r(:, irep), ndim, &
                         rep_env%f(ndim + 1, irep), rep_env%f(:ndim, irep), &
                         my_calc_f, ierr)
         CPASSERT(ierr == 0)
      END DO
      CALL rep_env_sync(rep_env, rep_env%f)
      CALL rep_env_sync_results(rep_env, rep_env%results)

   END SUBROUTINE rep_env_calc_e_f_int

END MODULE replica_methods
