!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!
MODULE optbas_fenv_manipulation
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind
   USE basis_set_container_types,       ONLY: get_basis_from_container
   USE basis_set_types,                 ONLY: gto_basis_set_type,&
                                              init_orb_basis_set
   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm
   USE cp_fm_basic_linalg,              ONLY: cp_fm_upper_to_full
   USE cp_fm_cholesky,                  ONLY: cp_fm_cholesky_decompose,&
                                              cp_fm_cholesky_invert
   USE cp_fm_pool_types,                ONLY: cp_fm_pool_p_type
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE cp_log_handling,                 ONLY: cp_to_string
   USE cp_output_handling,              ONLY: debug_print_level
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_get_info,&
                                              dbcsr_p_type,&
                                              dbcsr_type
   USE input_section_types,             ONLY: section_vals_get,&
                                              section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get,&
                                              section_vals_val_set
   USE kinds,                           ONLY: default_string_length
   USE optimize_basis_types,            ONLY: basis_optimization_type,&
                                              flex_basis_type
   USE particle_types,                  ONLY: particle_type
   USE qs_density_matrices,             ONLY: calculate_density_matrix
   USE qs_energy_init,                  ONLY: qs_energies_init
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_interactions,                 ONLY: init_interaction_radii
   USE qs_kind_types,                   ONLY: qs_kind_type
   USE qs_ks_methods,                   ONLY: qs_ks_update_qs_env
   USE qs_ks_types,                     ONLY: qs_ks_did_change
   USE qs_matrix_pools,                 ONLY: mpools_get
   USE qs_mo_io,                        ONLY: read_mo_set_from_restart
   USE qs_mo_types,                     ONLY: init_mo_set,&
                                              mo_set_type
   USE qs_rho_methods,                  ONLY: qs_rho_update_rho
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE string_utilities,                ONLY: uppercase
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: modify_input_settings, &
             allocate_mo_sets, &
             update_basis_set, &
             calculate_ks_matrix, &
             calculate_overlap_inverse

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'optbas_fenv_manipulation'

CONTAINS

! **************************************************************************************************
!> \brief change settings in the training input files to initialize
!>        all needed structures and adjust settings to basis optimization
!> \param basis_optimization ...
!> \param bas_id ...
!> \param input_file ...
!> \author Florian Schiffmann
! **************************************************************************************************
   SUBROUTINE modify_input_settings(basis_optimization, bas_id, input_file)
      TYPE(basis_optimization_type)                      :: basis_optimization
      INTEGER                                            :: bas_id
      TYPE(section_vals_type), POINTER                   :: input_file

      CHARACTER(LEN=default_string_length)               :: atom
      CHARACTER(LEN=default_string_length), &
         DIMENSION(:), POINTER                           :: abasinfo, obasinfo
      INTEGER                                            :: ibasis, ikind, jkind, nbasis, nkind
      TYPE(section_vals_type), POINTER                   :: dft_section, feval_section, &
                                                            kind_section, subsys_section

      feval_section => section_vals_get_subs_vals(input_file, "FORCE_EVAL")
      dft_section => section_vals_get_subs_vals(feval_section, "DFT")
      subsys_section => section_vals_get_subs_vals(feval_section, "SUBSYS")
      kind_section => section_vals_get_subs_vals(subsys_section, "KIND")

      CALL section_vals_val_set(feval_section, "PRINT%DISTRIBUTION%_SECTION_PARAMETERS_", &
                                i_val=debug_print_level)
      CALL section_vals_val_set(dft_section, "SCF%PRINT%TOTAL_DENSITIES%_SECTION_PARAMETERS_", &
                                i_val=debug_print_level)
      CALL section_vals_val_set(dft_section, "SCF%PRINT%DETAILED_ENERGY%_SECTION_PARAMETERS_", &
                                i_val=debug_print_level)

      ! add the new basis file containing the templates to the basis file list
      CALL section_vals_val_get(dft_section, "BASIS_SET_FILE_NAME", n_rep_val=nbasis)
      CALL section_vals_val_set(dft_section, "BASIS_SET_FILE_NAME", i_rep_val=nbasis + 1, &
                                c_val=basis_optimization%work_basis_file)

      ! Set the auxilarry basis in the kind sections
      CALL section_vals_get(kind_section, n_repetition=nkind)
      DO ikind = 1, nkind
         CALL section_vals_val_get(kind_section, "_SECTION_PARAMETERS_", &
                                   c_val=atom, i_rep_section=ikind)
         CALL uppercase(atom)
         CALL section_vals_val_get(kind_section, "BASIS_SET", n_rep_val=nbasis, i_rep_section=ikind)
         IF (nbasis > 1) THEN
            CALL cp_abort(__LOCATION__, &
                          "Basis set optimization: Only one single BASIS_SET allowed per KIND in the reference input")
         END IF
         CALL section_vals_val_get(kind_section, "BASIS_SET", &
                                   c_vals=obasinfo, i_rep_val=1, i_rep_section=ikind)
         ALLOCATE (abasinfo(2))
         abasinfo(1) = "AUX_OPT"
         IF (SIZE(obasinfo) == 1) THEN
            abasinfo(2) = obasinfo(1)
         ELSE
            abasinfo(2) = obasinfo(2)
         END IF
         CALL section_vals_val_set(kind_section, "BASIS_SET", &
                                   c_vals_ptr=abasinfo, i_rep_val=2, i_rep_section=ikind)
         CALL section_vals_val_get(kind_section, "BASIS_SET", n_rep_val=nbasis, i_rep_section=ikind)
         CPASSERT(nbasis == 2)

         DO jkind = 1, basis_optimization%nkind
            IF (atom == basis_optimization%kind_basis(jkind)%element) THEN

               NULLIFY (abasinfo)
               CALL section_vals_val_get(kind_section, "BASIS_SET", &
                                         c_vals=abasinfo, i_rep_val=2, i_rep_section=ikind)
               ibasis = basis_optimization%combination(bas_id, jkind)
               CPASSERT(SIZE(abasinfo) == 2)
               CPASSERT(abasinfo(1) == "AUX_OPT")
               abasinfo(2) = TRIM(ADJUSTL(basis_optimization%kind_basis(jkind)%flex_basis(ibasis)%basis_name))
               EXIT
            END IF
         END DO
      END DO

   END SUBROUTINE modify_input_settings

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
! **************************************************************************************************
   SUBROUTINE allocate_mo_sets(qs_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env

      INTEGER                                            :: ispin
      INTEGER, DIMENSION(2)                              :: nelectron_spin
      LOGICAL                                            :: natom_mismatch
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cp_fm_pool_p_type), DIMENSION(:), POINTER     :: ao_mo_fm_pools
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(section_vals_type), POINTER                   :: dft_section

      NULLIFY (para_env)
      CALL get_qs_env(qs_env=qs_env, &
                      dft_control=dft_control, &
                      mos=mos, nelectron_spin=nelectron_spin, &
                      atomic_kind_set=atomic_kind_set, &
                      qs_kind_set=qs_kind_set, &
                      particle_set=particle_set, &
                      para_env=para_env)
      dft_section => section_vals_get_subs_vals(qs_env%input, "DFT")

      CALL mpools_get(qs_env%mpools, ao_mo_fm_pools=ao_mo_fm_pools)
      DO ispin = 1, dft_control%nspins
         IF (.NOT. ASSOCIATED(mos(ispin)%mo_coeff)) THEN
            CALL init_mo_set(mos(ispin), &
                             fm_pool=ao_mo_fm_pools(ispin)%pool, &
                             name="qs_env%mo"//TRIM(ADJUSTL(cp_to_string(ispin))))
         END IF
      END DO

      CALL read_mo_set_from_restart(mos, atomic_kind_set, qs_kind_set, particle_set, para_env, &
                                    id_nr=0, multiplicity=dft_control%multiplicity, dft_section=dft_section, &
                                    natom_mismatch=natom_mismatch)

   END SUBROUTINE allocate_mo_sets

! **************************************************************************************************
!> \brief ...
!> \param qs_env ...
! **************************************************************************************************
   SUBROUTINE calculate_ks_matrix(qs_env)
      TYPE(qs_environment_type), POINTER                 :: qs_env

      INTEGER                                            :: ispin
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(qs_rho_type), POINTER                         :: rho

      NULLIFY (rho, dft_control, rho_ao)

      CALL qs_energies_init(qs_env, .FALSE.)
      CALL get_qs_env(qs_env, rho=rho, dft_control=dft_control)
      CALL qs_rho_get(rho, rho_ao=rho_ao)
      DO ispin = 1, dft_control%nspins
         CALL calculate_density_matrix(qs_env%mos(ispin), rho_ao(ispin)%matrix)
      END DO
      CALL qs_rho_update_rho(rho, qs_env)
      CALL qs_ks_did_change(qs_env%ks_env, rho_changed=.TRUE.)
      qs_env%requires_mo_derivs = .FALSE.
      CALL qs_ks_update_qs_env(qs_env, calculate_forces=.FALSE.)

   END SUBROUTINE calculate_ks_matrix

! **************************************************************************************************
!> \brief ...
!> \param matrix_s ...
!> \param matrix_s_inv ...
!> \param para_env ...
!> \param context ...
! **************************************************************************************************
   SUBROUTINE calculate_overlap_inverse(matrix_s, matrix_s_inv, para_env, context)
      TYPE(dbcsr_type), POINTER                          :: matrix_s
      TYPE(cp_fm_type), INTENT(OUT)                      :: matrix_s_inv
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_blacs_env_type), POINTER                   :: context

      INTEGER                                            :: nao
      TYPE(cp_fm_struct_type), POINTER                   :: fm_struct_tmp
      TYPE(cp_fm_type)                                   :: work1

      CALL dbcsr_get_info(matrix_s, nfullrows_total=nao)
      CALL cp_fm_struct_create(fm_struct_tmp, nrow_global=nao, ncol_global=nao, &
                               para_env=para_env, context=context)

      CALL cp_fm_create(matrix_s_inv, matrix_struct=fm_struct_tmp)
      CALL cp_fm_create(work1, matrix_struct=fm_struct_tmp)
      CALL copy_dbcsr_to_fm(matrix_s, matrix_s_inv)
      CALL cp_fm_upper_to_full(matrix_s_inv, work1)
      CALL cp_fm_cholesky_decompose(matrix_s_inv)
      CALL cp_fm_cholesky_invert(matrix_s_inv)
      CALL cp_fm_upper_to_full(matrix_s_inv, work1)
      CALL cp_fm_struct_release(fm_struct_tmp)
      CALL cp_fm_release(work1)

   END SUBROUTINE calculate_overlap_inverse

! **************************************************************************************************
!> \brief ...
!> \param opt_bas ...
!> \param bas_id ...
!> \param basis_type ...
!> \param qs_env ...
! **************************************************************************************************
   SUBROUTINE update_basis_set(opt_bas, bas_id, basis_type, qs_env)
      TYPE(basis_optimization_type)                      :: opt_bas
      INTEGER                                            :: bas_id
      CHARACTER(*)                                       :: basis_type
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(default_string_length)                   :: elem
      INTEGER                                            :: ibasis, ikind, jkind
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(gto_basis_set_type), POINTER                  :: gto_basis
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set

      CALL get_qs_env(qs_env=qs_env, dft_control=dft_control, &
                      atomic_kind_set=atomic_kind_set, qs_kind_set=qs_kind_set)
      DO ikind = 1, SIZE(qs_kind_set)
         DO jkind = 1, opt_bas%nkind
            CALL get_atomic_kind(atomic_kind_set(ikind), name=elem)
            CALL uppercase(elem)
            IF (elem == opt_bas%kind_basis(jkind)%element) THEN
               ibasis = opt_bas%combination(bas_id, jkind)
               CALL get_basis_from_container(qs_kind_set(ikind)%basis_sets, basis_set=gto_basis, &
                                             basis_type=basis_type)
               CALL transfer_data_to_gto(gto_basis, opt_bas%kind_basis(jkind)%flex_basis(ibasis))
               CALL init_orb_basis_set(gto_basis)
            END IF
         END DO
      END DO

      CALL init_interaction_radii(dft_control%qs_control, qs_kind_set)

   END SUBROUTINE update_basis_set

! **************************************************************************************************
!> \brief ...
!> \param gto_basis ...
!> \param basis ...
! **************************************************************************************************
   SUBROUTINE transfer_data_to_gto(gto_basis, basis)
      TYPE(gto_basis_set_type), POINTER                  :: gto_basis
      TYPE(flex_basis_type)                              :: basis

      INTEGER                                            :: ipgf, iset, ishell

      DO iset = 1, basis%nsets
         DO ishell = 1, basis%subset(iset)%ncon_tot
            DO ipgf = 1, basis%subset(iset)%nexp
               gto_basis%gcc(ipgf, ishell, iset) = basis%subset(iset)%coeff(ipgf, ishell)
            END DO
         END DO
         DO ipgf = 1, basis%subset(iset)%nexp
            gto_basis%zet(ipgf, iset) = basis%subset(iset)%exps(ipgf)
         END DO
      END DO

   END SUBROUTINE transfer_data_to_gto

END MODULE optbas_fenv_manipulation
