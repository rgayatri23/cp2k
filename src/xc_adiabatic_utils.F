!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief
!>
!>
!> \par History
!>     refactoring 03-2011 [MI]
!> \author MI
! **************************************************************************************************
MODULE xc_adiabatic_utils

   USE cp_control_types,                ONLY: dft_control_type
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_p_type
   USE hfx_communication,               ONLY: scale_and_add_fock_to_ks_matrix
   USE hfx_derivatives,                 ONLY: derivatives_four_center
   USE hfx_types,                       ONLY: hfx_type
   USE input_constants,                 ONLY: do_adiabatic_hybrid_mcy3,&
                                              do_adiabatic_model_pade
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE pw_types,                        ONLY: pw_type
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_ks_types,                     ONLY: qs_ks_env_type
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE qs_vxc,                          ONLY: qs_vxc_create
   USE qs_vxc_atom,                     ONLY: calculate_vxc_atom
   USE xc_adiabatic_methods,            ONLY: rescale_MCY3_pade
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   ! *** Public subroutines ***
   PUBLIC :: rescale_xc_potential

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'xc_adiabatic_utils'

CONTAINS

! **************************************************************************************************
!> \brief
!>
!> \param qs_env ...
!> \param ks_matrix ...
!> \param rho ...
!> \param energy ...
!> \param v_rspace_new ...
!> \param v_tau_rspace ...
!> \param hf_energy ...
!> \param just_energy ...
!> \param calculate_forces ...
!> \param use_virial ...
! **************************************************************************************************
   SUBROUTINE rescale_xc_potential(qs_env, ks_matrix, rho, energy, v_rspace_new, v_tau_rspace, &
                                   hf_energy, just_energy, calculate_forces, use_virial)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: ks_matrix
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(pw_type), DIMENSION(:), POINTER               :: v_rspace_new, v_tau_rspace
      REAL(dp), DIMENSION(:)                             :: hf_energy
      LOGICAL, INTENT(in)                                :: just_energy, calculate_forces, use_virial

      CHARACTER(LEN=*), PARAMETER :: routineN = 'rescale_xc_potential'

      INTEGER                                            :: adiabatic_functional, adiabatic_model, &
                                                            handle, n_rep_hf, nimages
      LOGICAL                                            :: do_adiabatic_rescaling, do_hfx, gapw, &
                                                            gapw_xc
      REAL(dp)                                           :: adiabatic_lambda, adiabatic_omega, &
                                                            scale_dDFA, scale_ddW0, scale_dEx1, &
                                                            scale_dEx2, total_energy_xc
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao_resp
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: rho_ao
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(hfx_type), DIMENSION(:, :), POINTER           :: x_data
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho_xc
      TYPE(section_vals_type), POINTER                   :: adiabatic_rescaling_section, &
                                                            hfx_sections, input, xc_section

      CALL timeset(routineN, handle)
      NULLIFY (para_env, dft_control, adiabatic_rescaling_section, hfx_sections, &
               input, xc_section, rho_xc, ks_env, rho_ao, rho_ao_resp, x_data)

      CALL get_qs_env(qs_env, &
                      dft_control=dft_control, &
                      para_env=para_env, &
                      input=input, &
                      rho_xc=rho_xc, &
                      ks_env=ks_env, &
                      x_data=x_data)

      IF (x_data(1, 1)%do_hfx_ri) CPABORT("RI-HFX not compatible with this kinf of functionals")
      nimages = dft_control%nimages
      CPASSERT(nimages == 1)

      CALL qs_rho_get(rho, rho_ao_kp=rho_ao)

      adiabatic_rescaling_section => section_vals_get_subs_vals(input, "DFT%XC%ADIABATIC_RESCALING")
      CALL section_vals_get(adiabatic_rescaling_section, explicit=do_adiabatic_rescaling)
      hfx_sections => section_vals_get_subs_vals(input, "DFT%XC%HF")
      CALL section_vals_get(hfx_sections, explicit=do_hfx)
      CALL section_vals_get(hfx_sections, n_repetition=n_rep_hf)

      gapw = dft_control%qs_control%gapw
      gapw_xc = dft_control%qs_control%gapw_xc

      CALL section_vals_val_get(adiabatic_rescaling_section, "FUNCTIONAL_TYPE", &
                                i_val=adiabatic_functional)
      CALL section_vals_val_get(adiabatic_rescaling_section, "FUNCTIONAL_MODEL", &
                                i_val=adiabatic_model)
      CALL section_vals_val_get(adiabatic_rescaling_section, "LAMBDA", &
                                r_val=adiabatic_lambda)
      CALL section_vals_val_get(adiabatic_rescaling_section, "OMEGA", &
                                r_val=adiabatic_omega)
      SELECT CASE (adiabatic_functional)
      CASE (do_adiabatic_hybrid_mcy3)
         SELECT CASE (adiabatic_model)
         CASE (do_adiabatic_model_pade)
            IF (n_rep_hf /= 2) &
               CALL cp_abort(__LOCATION__, &
                             " For this kind of adiababatic hybrid functional 2 HF sections have to be provided. "// &
                             " Please check your input file.")
            CALL rescale_MCY3_pade(qs_env, hf_energy, energy, adiabatic_lambda, &
                                   adiabatic_omega, scale_dEx1, scale_ddW0, scale_dDFA, &
                                   scale_dEx2, total_energy_xc)

            !! Scale and add Fock matrix to KS matrix
            IF (do_hfx) THEN
               CALL scale_and_add_fock_to_ks_matrix(para_env, qs_env, ks_matrix, 1, &
                                                    scale_dEx1)
               CALL scale_and_add_fock_to_ks_matrix(para_env, qs_env, ks_matrix, 2, &
                                                    scale_dEx2)
            END IF
            IF (calculate_forces) THEN
               CPASSERT(.NOT. use_virial)
               !! we also have to scale the forces!!!!
               CALL derivatives_four_center(qs_env, rho_ao, rho_ao_resp, hfx_sections, &
                                            para_env, 1, use_virial, &
                                            adiabatic_rescale_factor=scale_dEx1)
               CALL derivatives_four_center(qs_env, rho_ao, rho_ao_resp, hfx_sections, &
                                            para_env, 2, use_virial, &
                                            adiabatic_rescale_factor=scale_dEx2)
            END IF

            ! Calculate vxc and rescale it
            xc_section => section_vals_get_subs_vals(input, "DFT%XC")
            IF (gapw_xc) THEN
               CALL qs_vxc_create(ks_env=ks_env, rho_struct=rho_xc, xc_section=xc_section, &
                                  vxc_rho=v_rspace_new, vxc_tau=v_tau_rspace, exc=energy%exc, &
                                  just_energy=just_energy, adiabatic_rescale_factor=scale_dDFA)
            ELSE
               CALL qs_vxc_create(ks_env=ks_env, rho_struct=rho, xc_section=xc_section, &
                                  vxc_rho=v_rspace_new, vxc_tau=v_tau_rspace, exc=energy%exc, &
                                  just_energy=just_energy, adiabatic_rescale_factor=scale_dDFA)
            END IF

            ! Calculate vxc and rescale it
            IF (gapw .OR. gapw_xc) THEN
               CALL calculate_vxc_atom(qs_env, just_energy, energy%exc1, adiabatic_rescale_factor=scale_dDFA)
            END IF
            !! Hack for the total energy expression
            energy%ex = 0.0_dp
            energy%exc1 = 0.0_dp
            energy%exc = total_energy_xc

         END SELECT
      END SELECT
      CALL timestop(handle)

   END SUBROUTINE rescale_xc_potential

END MODULE xc_adiabatic_utils

