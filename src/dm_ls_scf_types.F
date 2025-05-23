!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Types needed for a linear scaling quickstep SCF run based on the density
!>        matrix
!> \par History
!>       2010.10 created [Joost VandeVondele]
!> \author Joost VandeVondele
! **************************************************************************************************
MODULE dm_ls_scf_types
   USE cp_para_env,                     ONLY: cp_para_env_release
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_release,&
                                              dbcsr_type
   USE input_constants,                 ONLY: ls_cluster_atomic,&
                                              ls_cluster_molecular
   USE input_section_types,             ONLY: section_vals_release,&
                                              section_vals_type
   USE kinds,                           ONLY: dp
   USE pao_types,                       ONLY: pao_env_type,&
                                              pao_finalize
   USE pexsi_types,                     ONLY: lib_pexsi_env,&
                                              lib_pexsi_finalize
   USE qs_density_mixing_types,         ONLY: mixing_storage_release,&
                                              mixing_storage_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dm_ls_scf_types'

   PUBLIC :: ls_scf_env_type, ls_mstruct_type, ls_cluster_atomic, ls_cluster_molecular, &
             ls_scf_curvy_type

   TYPE ls_mstruct_type
      INTEGER :: cluster_type
      LOGICAL :: single_precision
      LOGICAL :: do_pao
      INTEGER, DIMENSION(:), ALLOCATABLE :: atom_to_molecule
      TYPE(dbcsr_type)                :: matrix_A
      TYPE(dbcsr_type)                :: matrix_B
   END TYPE

   TYPE ls_mat_history_type
      INTEGER :: istore, nstore
      TYPE(dbcsr_type), DIMENSION(:, :), ALLOCATABLE :: matrix
   END TYPE

   TYPE ls_scf_curvy_type
      TYPE(dbcsr_type), DIMENSION(:), ALLOCATABLE :: matrix_dp
      TYPE(dbcsr_type), DIMENSION(:), ALLOCATABLE :: matrix_p
      TYPE(dbcsr_type), DIMENSION(:, :), ALLOCATABLE :: matrix_psave
      TYPE(dbcsr_type), DIMENSION(:, :), ALLOCATABLE :: matrix_BCH
      REAL(KIND=dp)                                    :: step_size(2)
      REAL(KIND=dp)                                    :: shift(2)
      REAL(KIND=dp)                                    :: cg_denom(2)
      REAL(KIND=dp)                                    :: cg_numer(2)
      REAL(KIND=dp), DIMENSION(6)                      :: energies
      INTEGER                                          :: line_search_step
      INTEGER                                          :: BCH_saved(2)
      LOGICAL                                          :: double_step_size
      LOGICAL                                          :: fix_shift(2)

      INTEGER                                          :: line_search_type
      INTEGER                                          :: n_bch_hist
      REAL(KIND=dp)                                    :: scale_filter
      REAL(KIND=dp)                                    :: filter_factor
      REAL(KIND=dp)                                    :: min_shift
      REAL(KIND=dp)                                    :: min_filter
   END TYPE

   TYPE chebyshev_type
      LOGICAL :: compute_chebyshev
      INTEGER :: n_chebyshev
      INTEGER :: n_gridpoint_dos
      REAL(KIND=dp), DIMENSION(:), POINTER :: min_energy => NULL()
      REAL(KIND=dp), DIMENSION(:), POINTER :: max_energy => NULL()
      TYPE(section_vals_type), POINTER :: print_key_dos => NULL()
      TYPE(section_vals_type), POINTER :: print_key_cube => NULL()
   END TYPE

   TYPE ls_scf_env_type
      INTEGER               :: nspins, natoms
      INTEGER               :: nelectron_total
      INTEGER, DIMENSION(2) :: nelectron_spin
      REAL(KIND=dp), DIMENSION(2) ::  mu_spin
      REAL(KIND=dp), DIMENSION(2) ::  homo_spin
      REAL(KIND=dp), DIMENSION(2) ::  lumo_spin

      TYPE(ls_mat_history_type) :: scf_history
      INTEGER :: extrapolation_order

      LOGICAL :: has_unit_metric

      LOGICAL :: curvy_steps
      INTEGER :: s_preconditioner_type
      INTEGER :: s_inversion_type
      INTEGER :: purification_method
      INTEGER :: sign_method
      INTEGER :: sign_order
      LOGICAL :: sign_symmetric
      INTEGER :: submatrix_sign_method
      INTEGER :: s_sqrt_method
      INTEGER :: s_sqrt_order

      LOGICAL               :: needs_s_inv, has_s_preconditioner, fixed_mu, dynamic_threshold, check_s_inv
      LOGICAL               :: restart_read, restart_write, non_monotonic
      REAL(KIND=dp)         :: eps_filter, eps_scf

      REAL(KIND=dp)         :: eps_lanczos
      INTEGER               :: max_iter_lanczos

      REAL(KIND=dp)         :: mixing_fraction
      INTEGER               :: max_scf
      LOGICAL               :: ls_diis
      INTEGER               :: iter_ini_diis
      INTEGER               :: nmixing, max_diis
      REAL(KIND=dp)         :: eps_diis
      REAL(KIND=dp)         :: energy_init

      TYPE(dbcsr_type)   :: matrix_s_inv
      TYPE(dbcsr_type)   :: matrix_s
      TYPE(dbcsr_type)   :: matrix_bs_sqrt, matrix_bs_sqrt_inv
      TYPE(dbcsr_type)   :: matrix_s_sqrt, matrix_s_sqrt_inv
      TYPE(dbcsr_type), DIMENSION(:), ALLOCATABLE :: matrix_ks
      TYPE(dbcsr_type), DIMENSION(:), ALLOCATABLE :: matrix_p

      LOGICAL  :: report_all_sparsities, perform_mu_scan, use_s_sqrt

      TYPE(ls_mstruct_type) :: ls_mstruct
      TYPE(ls_scf_curvy_type) :: curvy_data

      TYPE(chebyshev_type) :: chebyshev

      LOGICAL :: do_rho_mixing
      INTEGER :: density_mixing_method
      TYPE(mixing_storage_type), POINTER :: mixing_store

      LOGICAL :: do_transport
      LOGICAL :: do_pexsi

      LOGICAL :: calculate_forces

      TYPE(lib_pexsi_env) :: pexsi

      TYPE(cp_para_env_type), POINTER :: para_env
      LOGICAL                 :: do_pao = .FALSE.
      TYPE(pao_env_type)      :: pao_env
   END TYPE ls_scf_env_type

   PUBLIC :: ls_scf_release

CONTAINS

! **************************************************************************************************
!> \brief release the LS type.
!> \param ls_scf_env ...
!> \par History
!>       2012.11 created [Joost VandeVondele]
!> \author Joost VandeVondele
! **************************************************************************************************
   SUBROUTINE ls_scf_release(ls_scf_env)
      TYPE(ls_scf_env_type), POINTER                     :: ls_scf_env

      CHARACTER(len=*), PARAMETER                        :: routineN = 'ls_scf_release'

      INTEGER                                            :: handle, ispin, istore

      CALL timeset(routineN, handle)

      CALL cp_para_env_release(ls_scf_env%para_env)

      DEALLOCATE (ls_scf_env%ls_mstruct%atom_to_molecule)

      ! set up the buffer for the history of matrices
      DO istore = 1, MIN(ls_scf_env%scf_history%istore, ls_scf_env%scf_history%nstore)
         DO ispin = 1, SIZE(ls_scf_env%scf_history%matrix, 1)
            CALL dbcsr_release(ls_scf_env%scf_history%matrix(ispin, istore))
         END DO
      END DO
      DEALLOCATE (ls_scf_env%scf_history%matrix)

      IF (ALLOCATED(ls_scf_env%matrix_p)) THEN
         DO ispin = 1, SIZE(ls_scf_env%matrix_p)
            CALL dbcsr_release(ls_scf_env%matrix_p(ispin))
         END DO
         DEALLOCATE (ls_scf_env%matrix_p)
      END IF

      IF (ASSOCIATED(ls_scf_env%chebyshev%print_key_dos)) &
         CALL section_vals_release(ls_scf_env%chebyshev%print_key_dos)
      IF (ASSOCIATED(ls_scf_env%chebyshev%print_key_cube)) &
         CALL section_vals_release(ls_scf_env%chebyshev%print_key_cube)
      IF (ASSOCIATED(ls_scf_env%chebyshev%min_energy)) THEN
         DEALLOCATE (ls_scf_env%chebyshev%min_energy)
      END IF
      IF (ASSOCIATED(ls_scf_env%chebyshev%max_energy)) THEN
         DEALLOCATE (ls_scf_env%chebyshev%max_energy)
      END IF

      IF (ASSOCIATED(ls_scf_env%mixing_store)) THEN
         CALL mixing_storage_release(ls_scf_env%mixing_store)
         DEALLOCATE (ls_scf_env%mixing_store)
      END IF

      IF (ls_scf_env%do_pexsi) THEN
         CALL lib_pexsi_finalize(ls_scf_env%pexsi)
      END IF

      IF (ls_scf_env%do_pao) &
         CALL pao_finalize(ls_scf_env%pao_env)

      DEALLOCATE (ls_scf_env)

      CALL timestop(handle)

   END SUBROUTINE ls_scf_release

END MODULE dm_ls_scf_types
