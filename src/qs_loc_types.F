!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief New version of the module for the localization of the molecular orbitals
!>      This should be able to use different definition of the spread functional
!>      It should also calculate the integrals analytically so that it can be
!>      used irrespective of the pw_env and the collocation of wfn on the grids
!>      It should also work with a selected set of states, instead than all of them,
!>      in this case one should check that the selected states have the same occupation number
!>      The spread functional can be only estimated, or also optimized by minimization
!>      and in principle also maximization should be available.
!>      This operations can be required irrespective of the printing requirements
!>      It would be highly desirable to do all this along a MD run every N steps,
!>      and have a trajectory of the centeroids of the localized wfn
!>      In addition these functions can be used for properties calculations
!>      like NMR and XAS. Therefore it is necessary that the rotated wfn are then copied
!>      in the mos fm matrix to be available for next use.
!> \author MI (05-2005)
! **************************************************************************************************
MODULE qs_loc_types

   USE cell_types,                      ONLY: cell_release,&
                                              cell_retain,&
                                              cell_type
   USE cp_array_utils,                  ONLY: cp_2d_r_p_type
   USE cp_fm_types,                     ONLY: cp_fm_p_type,&
                                              cp_fm_release
   USE cp_para_env,                     ONLY: cp_para_env_release,&
                                              cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_deallocate_matrix,&
                                              dbcsr_p_type
   USE distribution_1d_types,           ONLY: distribution_1d_release,&
                                              distribution_1d_retain,&
                                              distribution_1d_type
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE particle_types,                  ONLY: particle_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! *** Global parameters ***

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_loc_types'

! **************************************************************************************************
!> \brief contains all the info needed by quickstep to calculate
!>      the spread of a selected set of orbitals and if required
!>      to minimize or maximize the spread by rotation of the orbitals
!> \param para_env info for the distribution of the calculations
!> \param mo_coeff full matrix containing only the selected subset of orbitals
!> \param local_molecules molecules distributed
!> \param cell box that contains the system
!> \param localized_wfn_control variables and parameter that define the spread
!>                             functional and the optimization algorithm
!> \param particle_set position, type, ao_indexes etc for each atom
!> \param op_sm_set set of sparse matrices used to define the spread operator
!>                  when the functional is defined by the use operator acting on the
!>                  basis functions, e.g. the Berry phase definition
!>                  The matrix element of the type <a|O|b> are computed in initialization
!>                  of qs_loc_env
!> \param op_fm_set set of full matrices used to define the spread operator
!>                 when the functional has to be defined directly using the products of MOS
!>                 as in the case of the Pipek-Mezek definition.
!> \param weights for a spread defined as extension of the orbitral in the box, these
!>               factors renormalize with respect to the box size
!> \note
!>      this type should replace the previous set up for the localization of the wfn
!> \par History
!>      04-05 created
!> \author MI
! **************************************************************************************************
   TYPE qs_loc_env_type
      LOGICAL :: molecular_states, do_localize, first_time
      LOGICAL :: wannier_states
      CHARACTER(LEN=default_string_length)        :: tag_mo
      TYPE(cp_para_env_type), POINTER          :: para_env
      TYPE(cp_fm_p_type), DIMENSION(:), &
         POINTER                                :: moloc_coeff
      TYPE(cp_fm_p_type), DIMENSION(:, :), &
         POINTER                                :: op_fm_set
      TYPE(distribution_1d_type), POINTER         :: local_molecules
      TYPE(cell_type), POINTER                 :: cell
      TYPE(localized_wfn_control_type), &
         POINTER                                :: localized_wfn_control
      TYPE(particle_type), DIMENSION(:), &
         POINTER                                :: particle_set
      TYPE(dbcsr_p_type), DIMENSION(:, :), &
         POINTER                                :: op_sm_set

      REAL(KIND=dp)                            :: start_time, target_time
      REAL(KIND=dp)                            :: weights(6)
      INTEGER                                     :: dim_op
   END TYPE qs_loc_env_type

! **************************************************************************************************
!> \brief A type that holds controlling information for the
!>    calculation of the spread of wfn and the optimization of
!>    the spread functional
!> \param ref_count ...
!> \param localization_method which algorithm is used for the optimization
!> \param operator_type how the spread is defined
!> \param nloc_states number of states on which the spread is computed
!> \param set_of_states how to choose the states
!> \param lu_bound_states lower and upper bounds of the set of states
!>    print_cubes:
!>    print_centers:
!>    print_spreads:
!> \param loc_states list of states on which the spread is computed
!> \param centers_set arrais containing centers and spreads of the selected wfn
!> \param centers_file_name output file names
!> \param spreads_file_name output file names
! **************************************************************************************************
   TYPE localized_wfn_control_type
      INTEGER                              :: ref_count
      INTEGER                              :: min_or_max
      INTEGER                              :: localization_method
      INTEGER                              :: operator_type
      INTEGER, DIMENSION(2)                :: nloc_states, nguess
      INTEGER                              :: set_of_states
      INTEGER, DIMENSION(2, 2)              :: lu_bound_states
      INTEGER                              :: max_iter
      INTEGER                              :: out_each
      INTEGER                              :: nextra
      INTEGER                              :: coeff_po_guess, coeff_po_guess_mo_space
      REAL(KIND=dp)                        :: eps_localization
      REAL(KIND=dp)                        :: max_crazy_angle
      REAL(KIND=dp)                        :: crazy_scale
      REAL(KIND=dp)                        :: eps_occ
      REAL(KIND=dp), DIMENSION(2)          :: lu_ene_bound
      LOGICAL                              :: crazy_use_diag
      LOGICAL                              :: print_cubes, jacobi_fallback, jacobi_refinement
      LOGICAL                              :: print_centers
      LOGICAL                              :: print_spreads
      LOGICAL                              :: do_homo
      LOGICAL                              :: do_mixed, do_cg_po
      LOGICAL                              :: loc_restart
      LOGICAL                              :: use_history
      INTEGER, POINTER, DIMENSION(:, :)       :: loc_states
      TYPE(cp_2d_r_p_type), DIMENSION(2)   :: centers_set
   END TYPE localized_wfn_control_type

! *** Public ***
   PUBLIC :: qs_loc_env_create, qs_loc_env_release, &
             get_qs_loc_env, set_qs_loc_env, &
             localized_wfn_control_create, localized_wfn_control_release
   PUBLIC :: qs_loc_env_type, localized_wfn_control_type

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param qs_loc_env ...
!> \par History
!>      04-05 created
!> \author MI
! **************************************************************************************************
   SUBROUTINE qs_loc_env_create(qs_loc_env)

      TYPE(qs_loc_env_type), INTENT(OUT)                 :: qs_loc_env

      qs_loc_env%tag_mo = ""
      NULLIFY (qs_loc_env%para_env)
      NULLIFY (qs_loc_env%cell)
      NULLIFY (qs_loc_env%op_sm_set)
      NULLIFY (qs_loc_env%op_fm_set)
      NULLIFY (qs_loc_env%local_molecules)
      NULLIFY (qs_loc_env%moloc_coeff)
      NULLIFY (qs_loc_env%particle_set)
      NULLIFY (qs_loc_env%localized_wfn_control)
      qs_loc_env%weights = 0.0_dp

   END SUBROUTINE qs_loc_env_create

!****f* qs_loc_types/qs_loc_env_release [1.0] *

! **************************************************************************************************
!> \brief ...
!> \param qs_loc_env ...
!> \par History
!>      04-05 created
!> \author MI
! **************************************************************************************************
   SUBROUTINE qs_loc_env_release(qs_loc_env)

      TYPE(qs_loc_env_type), INTENT(INOUT)               :: qs_loc_env

      INTEGER                                            :: i, ii, j

      IF (ASSOCIATED(qs_loc_env%cell)) CALL cell_release(qs_loc_env%cell)
      IF (ASSOCIATED(qs_loc_env%local_molecules)) &
         CALL distribution_1d_release(qs_loc_env%local_molecules)
      IF (ASSOCIATED(qs_loc_env%localized_wfn_control)) THEN
         CALL localized_wfn_control_release(qs_loc_env%localized_wfn_control)
      END IF
      IF (ASSOCIATED(qs_loc_env%para_env)) CALL cp_para_env_release(qs_loc_env%para_env)
      IF (ASSOCIATED(qs_loc_env%particle_set)) NULLIFY (qs_loc_env%particle_set)

      IF (ASSOCIATED(qs_loc_env%moloc_coeff)) THEN
         DO i = 1, SIZE(qs_loc_env%moloc_coeff, 1)
            ii = LBOUND(qs_loc_env%moloc_coeff, 1) + i - 1
            CALL cp_fm_release(qs_loc_env%moloc_coeff(ii)%matrix)
            DEALLOCATE (qs_loc_env%moloc_coeff(ii)%matrix)
            NULLIFY (qs_loc_env%moloc_coeff(ii)%matrix)
         END DO
         DEALLOCATE (qs_loc_env%moloc_coeff)
      END IF

      IF (ASSOCIATED(qs_loc_env%op_fm_set)) THEN
         DO i = 1, SIZE(qs_loc_env%op_fm_set, 2)
            DO j = 1, SIZE(qs_loc_env%op_fm_set, 1)
               CALL cp_fm_release(qs_loc_env%op_fm_set(j, i)%matrix)
               DEALLOCATE (qs_loc_env%op_fm_set(j, i)%matrix)
               NULLIFY (qs_loc_env%op_fm_set(j, i)%matrix)
            END DO
         END DO
         DEALLOCATE (qs_loc_env%op_fm_set)
      END IF

      IF (ASSOCIATED(qs_loc_env%op_sm_set)) THEN
         DO i = 1, SIZE(qs_loc_env%op_sm_set, 2)
            DO j = 1, SIZE(qs_loc_env%op_sm_set, 1)
               CALL dbcsr_deallocate_matrix(qs_loc_env%op_sm_set(j, i)%matrix)
            END DO
         END DO
         DEALLOCATE (qs_loc_env%op_sm_set)
      END IF

   END SUBROUTINE qs_loc_env_release

! **************************************************************************************************
!> \brief create the localized_wfn_control_type
!> \param localized_wfn_control ...
!> \par History
!>      04.2005 created [MI]
! **************************************************************************************************
   SUBROUTINE localized_wfn_control_create(localized_wfn_control)
      TYPE(localized_wfn_control_type), POINTER          :: localized_wfn_control

      CPASSERT(.NOT. ASSOCIATED(localized_wfn_control))
      ALLOCATE (localized_wfn_control)

      localized_wfn_control%ref_count = 1
      localized_wfn_control%nloc_states = 0
      localized_wfn_control%nextra = 0
      localized_wfn_control%nguess = 0
      localized_wfn_control%lu_bound_states = 0
      localized_wfn_control%lu_ene_bound = 0.0_dp
      localized_wfn_control%print_cubes = .FALSE.
      localized_wfn_control%print_centers = .FALSE.
      localized_wfn_control%print_spreads = .FALSE.
      localized_wfn_control%do_homo = .TRUE.
      localized_wfn_control%use_history = .FALSE.
      NULLIFY (localized_wfn_control%loc_states)
      NULLIFY (localized_wfn_control%centers_set(1)%array)
      NULLIFY (localized_wfn_control%centers_set(2)%array)
   END SUBROUTINE localized_wfn_control_create

! **************************************************************************************************
!> \brief release the localized_wfn_control_type
!> \param localized_wfn_control ...
!> \par History
!>      04.2005 created [MI]
! **************************************************************************************************
   SUBROUTINE localized_wfn_control_release(localized_wfn_control)

      TYPE(localized_wfn_control_type), POINTER          :: localized_wfn_control

      IF (ASSOCIATED(localized_wfn_control)) THEN
         CPASSERT(localized_wfn_control%ref_count > 0)
         localized_wfn_control%ref_count = localized_wfn_control%ref_count - 1
         IF (localized_wfn_control%ref_count == 0) THEN
            IF (ASSOCIATED(localized_wfn_control%loc_states)) THEN
               DEALLOCATE (localized_wfn_control%loc_states)
            END IF
            IF (ASSOCIATED(localized_wfn_control%centers_set(1)%array)) THEN
               DEALLOCATE (localized_wfn_control%centers_set(1)%array)
            END IF
            IF (ASSOCIATED(localized_wfn_control%centers_set(2)%array)) THEN
               DEALLOCATE (localized_wfn_control%centers_set(2)%array)
            END IF
            localized_wfn_control%ref_count = 0
            DEALLOCATE (localized_wfn_control)
         END IF
      END IF
   END SUBROUTINE localized_wfn_control_release

! **************************************************************************************************
!> \brief retain the localized_wfn_control_type
!> \param localized_wfn_control ...
!> \par History
!>      04.2005 created [MI]
! **************************************************************************************************
   SUBROUTINE localized_wfn_control_retain(localized_wfn_control)
      TYPE(localized_wfn_control_type), POINTER          :: localized_wfn_control

      CPASSERT(ASSOCIATED(localized_wfn_control))

      localized_wfn_control%ref_count = localized_wfn_control%ref_count + 1
   END SUBROUTINE localized_wfn_control_retain

! **************************************************************************************************
!> \brief ...
!> \param qs_loc_env ...
!> \param cell ...
!> \param local_molecules ...
!> \param localized_wfn_control ...
!> \param moloc_coeff ...
!> \param op_sm_set ...
!> \param op_fm_set ...
!> \param para_env ...
!> \param particle_set ...
!> \param weights ...
!> \param dim_op ...
!> \par History
!>      04-05 created
!> \author MI
! **************************************************************************************************
   SUBROUTINE get_qs_loc_env(qs_loc_env, cell, local_molecules, localized_wfn_control, &
                             moloc_coeff, op_sm_set, op_fm_set, para_env, particle_set, weights, dim_op)

      TYPE(qs_loc_env_type), INTENT(IN)                  :: qs_loc_env
      TYPE(cell_type), OPTIONAL, POINTER                 :: cell
      TYPE(distribution_1d_type), OPTIONAL, POINTER      :: local_molecules
      TYPE(localized_wfn_control_type), OPTIONAL, &
         POINTER                                         :: localized_wfn_control
      TYPE(cp_fm_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: moloc_coeff
      TYPE(dbcsr_p_type), DIMENSION(:, :), OPTIONAL, &
         POINTER                                         :: op_sm_set
      TYPE(cp_fm_p_type), DIMENSION(:, :), OPTIONAL, &
         POINTER                                         :: op_fm_set
      TYPE(cp_para_env_type), OPTIONAL, POINTER          :: para_env
      TYPE(particle_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: particle_set
      REAL(dp), DIMENSION(6), OPTIONAL                   :: weights
      INTEGER, OPTIONAL                                  :: dim_op

      IF (PRESENT(cell)) cell => qs_loc_env%cell
      IF (PRESENT(moloc_coeff)) moloc_coeff => qs_loc_env%moloc_coeff
      IF (PRESENT(local_molecules)) local_molecules => qs_loc_env%local_molecules
      IF (PRESENT(localized_wfn_control)) &
         localized_wfn_control => qs_loc_env%localized_wfn_control
      IF (PRESENT(op_sm_set)) op_sm_set => qs_loc_env%op_sm_set
      IF (PRESENT(op_fm_set)) op_fm_set => qs_loc_env%op_fm_set
      IF (PRESENT(para_env)) para_env => qs_loc_env%para_env
      IF (PRESENT(particle_set)) particle_set => qs_loc_env%particle_set
      IF (PRESENT(weights)) weights(1:6) = qs_loc_env%weights(1:6)
      IF (PRESENT(dim_op)) dim_op = qs_loc_env%dim_op

   END SUBROUTINE get_qs_loc_env

! **************************************************************************************************
!> \brief ...
!> \param qs_loc_env ...
!> \param cell ...
!> \param local_molecules ...
!> \param localized_wfn_control ...
!> \param moloc_coeff ...
!> \param op_sm_set ...
!> \param op_fm_set ...
!> \param para_env ...
!> \param particle_set ...
!> \param weights ...
!> \param dim_op ...
!> \par History
!>      04-05 created
!> \author MI
! **************************************************************************************************
   SUBROUTINE set_qs_loc_env(qs_loc_env, cell, local_molecules, localized_wfn_control, &
                             moloc_coeff, op_sm_set, op_fm_set, para_env, particle_set, weights, dim_op)

      TYPE(qs_loc_env_type), INTENT(INOUT)               :: qs_loc_env
      TYPE(cell_type), OPTIONAL, POINTER                 :: cell
      TYPE(distribution_1d_type), OPTIONAL, POINTER      :: local_molecules
      TYPE(localized_wfn_control_type), OPTIONAL, &
         POINTER                                         :: localized_wfn_control
      TYPE(cp_fm_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: moloc_coeff
      TYPE(dbcsr_p_type), DIMENSION(:, :), OPTIONAL, &
         POINTER                                         :: op_sm_set
      TYPE(cp_fm_p_type), DIMENSION(:, :), OPTIONAL, &
         POINTER                                         :: op_fm_set
      TYPE(cp_para_env_type), OPTIONAL, POINTER          :: para_env
      TYPE(particle_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: particle_set
      REAL(dp), DIMENSION(6), OPTIONAL                   :: weights
      INTEGER, OPTIONAL                                  :: dim_op

      INTEGER                                            :: i

      IF (PRESENT(cell)) THEN
         CALL cell_retain(cell)
         CALL cell_release(qs_loc_env%cell)
         qs_loc_env%cell => cell
      END IF

      IF (PRESENT(local_molecules)) THEN
         CALL distribution_1d_retain(local_molecules)
         IF (ASSOCIATED(qs_loc_env%local_molecules)) &
            CALL distribution_1d_release(qs_loc_env%local_molecules)
         qs_loc_env%local_molecules => local_molecules
      END IF

      IF (PRESENT(localized_wfn_control)) THEN
         CALL localized_wfn_control_retain(localized_wfn_control)
         CALL localized_wfn_control_release(qs_loc_env%localized_wfn_control)
         qs_loc_env%localized_wfn_control => localized_wfn_control
      END IF
      IF (PRESENT(para_env)) THEN
         CALL cp_para_env_retain(para_env)
         CALL cp_para_env_release(qs_loc_env%para_env)
         qs_loc_env%para_env => para_env
      END IF
      IF (PRESENT(particle_set)) qs_loc_env%particle_set => particle_set
      IF (PRESENT(moloc_coeff)) THEN
         IF (ASSOCIATED(qs_loc_env%moloc_coeff)) THEN
            DO i = 1, SIZE(qs_loc_env%moloc_coeff, 1)
               CALL cp_fm_release(qs_loc_env%moloc_coeff(i)%matrix)
               DEALLOCATE (qs_loc_env%moloc_coeff(i)%matrix)
               NULLIFY (qs_loc_env%moloc_coeff(i)%matrix)
            END DO
            DEALLOCATE (qs_loc_env%moloc_coeff)
         END IF
         qs_loc_env%moloc_coeff => moloc_coeff
      END IF
      IF (PRESENT(op_sm_set)) THEN
         qs_loc_env%op_sm_set => op_sm_set
      END IF
      IF (PRESENT(op_fm_set)) THEN
         qs_loc_env%op_fm_set => op_fm_set
      END IF
      IF (PRESENT(weights)) THEN
         qs_loc_env%weights = weights
      END IF
      IF (PRESENT(dim_op)) THEN
         qs_loc_env%dim_op = dim_op
      END IF

   END SUBROUTINE set_qs_loc_env

END MODULE qs_loc_types

