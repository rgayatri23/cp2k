!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Routines to calculate 2nd order kernels from a given response density in ao basis
!>      linear response scf
!> \par History
!>      created 08-2020 [Frederick Stein], Code by M. Iannuzzi
!> \author Frederick Stein
! **************************************************************************************************
MODULE qs_2nd_kernel_ao
   USE admm_types,                      ONLY: admm_type,&
                                              get_admm_env
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_operations,             ONLY: cp_dbcsr_plus_fm_fm_t,&
                                              dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_fm_types,                     ONLY: cp_fm_get_info,&
                                              cp_fm_p_type
   USE dbcsr_api,                       ONLY: dbcsr_add,&
                                              dbcsr_copy,&
                                              dbcsr_create,&
                                              dbcsr_p_type,&
                                              dbcsr_release,&
                                              dbcsr_set
   USE hfx_admm_utils,                  ONLY: tddft_hfx_matrix
   USE input_constants,                 ONLY: do_admm_aux_exch_func_none,&
                                              do_admm_basis_projection,&
                                              do_admm_exch_scaling_none,&
                                              do_admm_purify_none
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type
   USE kinds,                           ONLY: dp
   USE pw_env_types,                    ONLY: pw_env_get,&
                                              pw_env_type
   USE pw_pool_types,                   ONLY: pw_pool_give_back_pw,&
                                              pw_pool_type
   USE pw_types,                        ONLY: pw_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_integrate_potential,          ONLY: integrate_v_rspace
   USE qs_kpp1_env_methods,             ONLY: calc_kpp1
   USE qs_ks_types,                     ONLY: qs_ks_env_type
   USE qs_linres_types,                 ONLY: linres_control_type
   USE qs_p_env_methods,                ONLY: p_env_finish_kpp1
   USE qs_p_env_types,                  ONLY: qs_p_env_type
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE task_list_types,                 ONLY: task_list_type
   USE xc,                              ONLY: xc_calc_2nd_deriv
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   ! *** Public subroutines ***
   PUBLIC :: build_dm_response, apply_2nd_order_kernel
   PUBLIC :: apply_hfx_ao
   PUBLIC :: apply_xc_admm_ao

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_2nd_kernel_ao'

! **************************************************************************************************

CONTAINS

! **************************************************************************************************
!> \brief This routine builds response density in dbcsr format
!> \param c0 coefficients of unperturbed system (not changed)
!> \param c1 coefficients of response (not changed)
!> \param dm response density matrix
! **************************************************************************************************
   SUBROUTINE build_dm_response(c0, c1, dm)
      !
      TYPE(cp_fm_p_type), DIMENSION(:), INTENT(IN)       :: c0, c1
      TYPE(dbcsr_p_type), DIMENSION(:), INTENT(INOUT)    :: dm

      INTEGER                                            :: ispin, ncol, nspins

      nspins = SIZE(dm, 1)

      DO ispin = 1, nspins
         CALL dbcsr_set(dm(ispin)%matrix, 0.0_dp)
         CALL cp_fm_get_info(c0(ispin)%matrix, ncol_global=ncol)
         CALL cp_dbcsr_plus_fm_fm_t(dm(ispin)%matrix, &
                                    matrix_v=c0(ispin)%matrix, &
                                    matrix_g=c1(ispin)%matrix, &
                                    ncol=ncol, alpha=2.0_dp, &
                                    keep_sparsity=.TRUE., &
                                    symmetry_mode=1)
      END DO

   END SUBROUTINE build_dm_response

! **************************************************************************************************
!> \brief Calculate a second order kernel (DFT, HF, ADMM correction) for a given density
!> \param qs_env ...
!> \param p_env perturbation environment containing the correct density matrices p_env%p1, p_env%p1_admm,
!>        the kernel will be saved in p_env%kpp1, p_env%kpp1_admm
!> \param recalc_hfx_integrals whether to recalculate the HFX integrals
!> \param calc_forces whether to calculate forces
!> \param calc_virial whether to calculate virials
!> \param virial collect the virial terms from the XC + ADMM parts (terms from integration will be added to pv_virial)
! **************************************************************************************************
   SUBROUTINE apply_2nd_order_kernel(qs_env, p_env, recalc_hfx_integrals, calc_forces, calc_virial, virial)
      TYPE(qs_environment_type), INTENT(IN), POINTER     :: qs_env
      TYPE(qs_p_env_type)                                :: p_env
      LOGICAL, INTENT(IN), OPTIONAL                      :: recalc_hfx_integrals, calc_forces, &
                                                            calc_virial
      REAL(KIND=dp), DIMENSION(3, 3), INTENT(INOUT), &
         OPTIONAL                                        :: virial

      CHARACTER(LEN=*), PARAMETER :: routineN = 'apply_2nd_order_kernel'

      INTEGER                                            :: handle, ispin
      LOGICAL                                            :: do_hfx, my_calc_forces, my_calc_virial, &
                                                            my_recalc_hfx_integrals
      TYPE(admm_type), POINTER                           :: admm_env
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(linres_control_type), POINTER                 :: linres_control
      TYPE(section_vals_type), POINTER                   :: hfx_sections, input, xc_section

      CALL timeset(routineN, handle)

      my_recalc_hfx_integrals = .FALSE.
      IF (PRESENT(recalc_hfx_integrals)) my_recalc_hfx_integrals = recalc_hfx_integrals

      my_calc_forces = .FALSE.
      IF (PRESENT(calc_forces)) my_calc_forces = calc_forces

      my_calc_virial = .FALSE.
      IF (PRESENT(calc_virial)) my_calc_virial = calc_virial

      CALL get_qs_env(qs_env, dft_control=dft_control)

      DO ispin = 1, SIZE(p_env%kpp1)
         CALL dbcsr_set(p_env%kpp1(ispin)%matrix, 0.0_dp)
         IF (dft_control%do_admm) CALL dbcsr_set(p_env%kpp1_admm(ispin)%matrix, 0.0_dp)
      END DO

      CALL get_qs_env(qs_env=qs_env, &
                      input=input, &
                      linres_control=linres_control)

      IF (dft_control%do_admm) THEN
         CALL get_qs_env(qs_env, admm_env=admm_env)
         xc_section => admm_env%xc_section_primary
      ELSE
         xc_section => section_vals_get_subs_vals(input, "DFT%XC")
      END IF

      CALL calc_kpp1(p_env%rho1_xc, p_env%rho1, xc_section, .FALSE., &
                     .FALSE., dft_control%qs_control%lrigpw, .TRUE., linres_control%lr_triplet, &
                     qs_env, p_env, calc_forces=my_calc_forces, calc_virial=my_calc_virial, virial=virial)

      ! hfx section
      NULLIFY (hfx_sections)
      hfx_sections => section_vals_get_subs_vals(input, "DFT%XC%HF")
      CALL section_vals_get(hfx_sections, explicit=do_hfx)
      IF (do_hfx) THEN
         CALL apply_hfx_ao(qs_env, p_env, my_recalc_hfx_integrals)

         IF (dft_control%do_admm) THEN
            CALL apply_xc_admm_ao(qs_env, p_env, my_calc_forces, my_calc_virial, virial)
            CALL p_env_finish_kpp1(qs_env, p_env)
         END IF
      END IF

      CALL timestop(handle)

   END SUBROUTINE apply_2nd_order_kernel

! **************************************************************************************************
!> \brief This routine applies the Hartree-Fock Exchange kernel to a perturbation density matrix considering ADMM
!> \param qs_env the Quickstep environment
!> \param p_env perturbation environment from which p1/p1_admm and kpp1/kpp1_admm are taken
!> \param recalc_integrals whether the integrals are to be recalculated (default: no)
! **************************************************************************************************
   SUBROUTINE apply_hfx_ao(qs_env, p_env, recalc_integrals)
      TYPE(qs_environment_type), INTENT(IN), POINTER     :: qs_env
      TYPE(qs_p_env_type), INTENT(IN)                    :: p_env
      LOGICAL, INTENT(IN), OPTIONAL                      :: recalc_integrals

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'apply_hfx_ao'

      INTEGER                                            :: handle, ispin, nspins
      LOGICAL                                            :: my_recalc_integrals
      REAL(KIND=dp)                                      :: alpha
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: h1_mat, rho1, work_hmat
      TYPE(dft_control_type), POINTER                    :: dft_control

      CALL timeset(routineN, handle)

      my_recalc_integrals = .FALSE.
      IF (PRESENT(recalc_integrals)) my_recalc_integrals = recalc_integrals

      CALL get_qs_env(qs_env=qs_env, dft_control=dft_control)

      IF (dft_control%do_admm) THEN
         IF (dft_control%admm_control%purification_method /= do_admm_purify_none) THEN
            CPABORT("ADMM: Linear Response needs purification_method=none")
         END IF
         IF (dft_control%admm_control%scaling_model /= do_admm_exch_scaling_none) THEN
            CPABORT("ADMM: Linear Response needs scaling_model=none")
         END IF
         IF (dft_control%admm_control%method /= do_admm_basis_projection) THEN
            CPABORT("ADMM: Linear Response needs admm_method=basis_projection")
         END IF
         !
      END IF

      nspins = dft_control%nspins

      IF (dft_control%do_admm) THEN
         rho1 => p_env%p1_admm
         h1_mat => p_env%kpp1_admm
      ELSE
         rho1 => p_env%p1
         h1_mat => p_env%kpp1
      END IF

      DO ispin = 1, nspins
         CPASSERT(ASSOCIATED(rho1(ispin)%matrix))
         CPASSERT(ASSOCIATED(h1_mat(ispin)%matrix))
      END DO

      NULLIFY (work_hmat)
      CALL dbcsr_allocate_matrix_set(work_hmat, nspins)
      DO ispin = 1, nspins
         ALLOCATE (work_hmat(ispin)%matrix)
         CALL dbcsr_create(work_hmat(ispin)%matrix, template=rho1(ispin)%matrix)
         CALL dbcsr_copy(work_hmat(ispin)%matrix, rho1(ispin)%matrix)
         CALL dbcsr_set(work_hmat(ispin)%matrix, 0.0_dp)
      END DO

      ! Calculate kernel
      CALL tddft_hfx_matrix(work_hmat, rho1, qs_env, .FALSE., my_recalc_integrals)

      alpha = 2.0_dp
      IF (nspins == 2) alpha = 1.0_dp

      DO ispin = 1, nspins
         CALL dbcsr_add(h1_mat(ispin)%matrix, work_hmat(ispin)%matrix, 1.0_dp, alpha)
      END DO

      CALL dbcsr_deallocate_matrix_set(work_hmat)

      CALL timestop(handle)

   END SUBROUTINE apply_hfx_ao

! **************************************************************************************************
!> \brief apply the kernel from the ADMM exchange correction
!> \param qs_env ...
!> \param p_env perturbation environment
!> \param calc_forces whether to calculate forces
!> \param calc_virial whether to calculate gradients
!> \param virial collects the virial terms from the XC functional (virial terms from integration are collected in pv_virial)
! **************************************************************************************************
   SUBROUTINE apply_xc_admm_ao(qs_env, p_env, calc_forces, calc_virial, virial)
      TYPE(qs_environment_type), INTENT(IN), POINTER     :: qs_env
      TYPE(qs_p_env_type)                                :: p_env
      LOGICAL, INTENT(IN), OPTIONAL                      :: calc_forces, calc_virial
      REAL(KIND=dp), DIMENSION(3, 3), INTENT(INOUT), &
         OPTIONAL                                        :: virial

      CHARACTER(len=*), PARAMETER                        :: routineN = 'apply_xc_admm_ao'

      INTEGER                                            :: handle, ispin, nao, nao_aux, nspins
      LOGICAL                                            :: lsd, my_calc_forces
      REAL(KIND=dp)                                      :: alpha
      TYPE(admm_type), POINTER                           :: admm_env
      TYPE(dbcsr_p_type)                                 :: work_hmat
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao_aux
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(linres_control_type), POINTER                 :: linres_control
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool
      TYPE(pw_type), DIMENSION(:), POINTER               :: rho1_aux_g, rho1_aux_r, tau1_aux_r, &
                                                            v_xc, v_xc_tau
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho_aux
      TYPE(section_vals_type), POINTER                   :: xc_section
      TYPE(task_list_type), POINTER                      :: task_list_aux_fit

      CALL timeset(routineN, handle)

      CALL get_qs_env(qs_env=qs_env, dft_control=dft_control)

      IF (qs_env%admm_env%aux_exch_func /= do_admm_aux_exch_func_none) THEN
         CALL get_qs_env(qs_env=qs_env, linres_control=linres_control)
         CPASSERT(.NOT. dft_control%qs_control%gapw)
         CPASSERT(.NOT. dft_control%qs_control%gapw_xc)
         CPASSERT(.NOT. dft_control%qs_control%lrigpw)
         CPASSERT(.NOT. linres_control%lr_triplet)
         IF (.NOT. ASSOCIATED(p_env%kpp1_admm)) &
            CPABORT("kpp1_admm has to be associated if ADMM kernel calculations are requested")

         nspins = dft_control%nspins

         my_calc_forces = .FALSE.
         IF (PRESENT(calc_forces)) my_calc_forces = calc_forces

         ! AUX basis contribution
         CALL get_qs_env(qs_env=qs_env, pw_env=pw_env)
         CPASSERT(ASSOCIATED(pw_env))
         CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool)
         NULLIFY (v_xc)
         ! calculate the xc potential
         lsd = (nspins == 2)
         CALL get_qs_env(qs_env=qs_env, ks_env=ks_env, admm_env=admm_env)
         CALL get_admm_env(admm_env, task_list_aux_fit=task_list_aux_fit)

         CALL qs_rho_get(p_env%rho1_admm, rho_r=rho1_aux_r, rho_g=rho1_aux_g, tau_r=tau1_aux_r)
         xc_section => admm_env%xc_section_aux

         CALL xc_calc_2nd_deriv(v_xc, v_xc_tau, p_env%kpp1_env%deriv_set_admm, &
                                p_env%kpp1_env%rho_set_admm, &
                                rho1_aux_r, rho1_aux_g, tau1_aux_r, auxbas_pw_pool, xc_section=xc_section, gapw=.FALSE., &
                                compute_virial=calc_virial, virial_xc=virial)

         NULLIFY (work_hmat%matrix)
         ALLOCATE (work_hmat%matrix)
         CALL dbcsr_copy(work_hmat%matrix, p_env%kpp1_admm(1)%matrix)

         alpha = 1.0_dp
         IF (nspins == 1) alpha = 2.0_dp

         CALL get_admm_env(qs_env%admm_env, rho_aux_fit=rho_aux)
         CALL qs_rho_get(rho_aux, rho_ao=rho_ao_aux)

         CALL cp_fm_get_info(admm_env%A, nrow_global=nao_aux, ncol_global=nao)
         DO ispin = 1, nspins
            v_xc(ispin)%cr3d = v_xc(ispin)%cr3d*v_xc(ispin)%pw_grid%dvol
            CALL dbcsr_set(work_hmat%matrix, 0.0_dp)
            CALL integrate_v_rspace(v_rspace=v_xc(ispin), hmat=work_hmat, qs_env=qs_env, &
                                    calculate_forces=my_calc_forces, basis_type="AUX_FIT", &
                                    task_list_external=task_list_aux_fit, pmat=rho_ao_aux(ispin))
            IF (ASSOCIATED(v_xc_tau)) THEN
               v_xc_tau(ispin)%cr3d = v_xc_tau(ispin)%cr3d*v_xc_tau(ispin)%pw_grid%dvol
               CALL integrate_v_rspace(v_rspace=v_xc_tau(ispin), hmat=work_hmat, qs_env=qs_env, &
                                       compute_tau=.TRUE., &
                                       calculate_forces=my_calc_forces, basis_type="AUX_FIT", &
                                       task_list_external=task_list_aux_fit, pmat=rho_ao_aux(ispin))
            END IF
            CALL dbcsr_add(p_env%kpp1_admm(ispin)%matrix, work_hmat%matrix, 1.0_dp, alpha)

         END DO

         CALL dbcsr_release(work_hmat%matrix)
         DEALLOCATE (work_hmat%matrix)

         DO ispin = 1, nspins
            CALL pw_pool_give_back_pw(auxbas_pw_pool, v_xc(ispin))
         END DO
         DEALLOCATE (v_xc)

      END IF

      CALL timestop(handle)

   END SUBROUTINE apply_xc_admm_ao
END MODULE qs_2nd_kernel_ao
