!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \par History
!>      - Container to hold basis sets
!> \author JGH (09.07.2015)
! **************************************************************************************************
MODULE basis_set_container_types

   USE basis_set_types,                 ONLY: deallocate_gto_basis_set,&
                                              gto_basis_set_type
   USE kinds,                           ONLY: default_string_length
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   ! Global parameters (only in this module)

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'basis_set_container_types'

! **************************************************************************************************
   INTEGER, PARAMETER                       :: unknown_basis = 100, &
                                               orbital_basis = 101, &
                                               auxiliary_basis = 102, &
                                               ri_aux_basis = 103, &
                                               lri_aux_basis = 104, &
                                               aux_fit_basis = 105, &
                                               soft_basis = 106, &
                                               hard_basis = 107, &
                                               mao_basis = 108, &
                                               harris_basis = 109, &
                                               aux_gw_basis = 110, &
                                               ri_hxc_basis = 111, &
                                               ri_k_basis = 112, &
                                               ri_xas_basis = 113, &
                                               aux_fit_soft_basis = 114, &
                                               ri_hfx_basis = 115, &
                                               p_lri_aux_basis = 116, &
                                               aux_opt_basis = 117
! **************************************************************************************************
   TYPE basis_set_container_type
      PRIVATE
      CHARACTER(LEN=default_string_length)       :: basis_type = ""
      INTEGER                                    :: basis_type_nr = 0
      TYPE(gto_basis_set_type), POINTER          :: basis_set => NULL()
   END TYPE basis_set_container_type
! **************************************************************************************************

   PUBLIC :: basis_set_container_type

   PUBLIC :: remove_basis_set_container, &
             add_basis_set_to_container, get_basis_from_container, &
             remove_basis_from_container

! **************************************************************************************************

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param basis ...
! **************************************************************************************************
   SUBROUTINE remove_basis_set_container(basis)
      TYPE(basis_set_container_type), DIMENSION(:), &
         INTENT(inout)                                   :: basis

      INTEGER                                            :: i

      DO i = 1, SIZE(basis)
         basis(i)%basis_type = ""
         basis(i)%basis_type_nr = 0
         IF (ASSOCIATED(basis(i)%basis_set)) THEN
            CALL deallocate_gto_basis_set(basis(i)%basis_set)
         END IF
      END DO

   END SUBROUTINE remove_basis_set_container

! **************************************************************************************************
!> \brief ...
!> \param basis_set_type ...
!> \return ...
! **************************************************************************************************
   FUNCTION get_basis_type(basis_set_type) RESULT(basis_type_nr)
      CHARACTER(len=*)                                   :: basis_set_type
      INTEGER                                            :: basis_type_nr

      SELECT CASE (basis_set_type)
      CASE ("ORB")
         basis_type_nr = orbital_basis
      CASE ("AUX")
         basis_type_nr = auxiliary_basis
      CASE ("RI_AUX")
         basis_type_nr = ri_aux_basis
      CASE ("RI_HXC")
         basis_type_nr = ri_hxc_basis
      CASE ("RI_HFX")
         basis_type_nr = ri_hfx_basis
      CASE ("RI_K")
         basis_type_nr = ri_k_basis
      CASE ("LRI_AUX")
         basis_type_nr = lri_aux_basis
      CASE ("P_LRI_AUX")
         basis_type_nr = p_lri_aux_basis
      CASE ("AUX_FIT")
         basis_type_nr = aux_fit_basis
      CASE ("AUX_FIT_SOFT")
         basis_type_nr = aux_fit_soft_basis
      CASE ("SOFT")
         basis_type_nr = soft_basis
      CASE ("HARD")
         basis_type_nr = hard_basis
      CASE ("MAO")
         basis_type_nr = mao_basis
      CASE ("HARRIS")
         basis_type_nr = harris_basis
      CASE ("AUX_GW")
         basis_type_nr = aux_gw_basis
      CASE ("RI_XAS")
         basis_type_nr = ri_xas_basis
      CASE ("AUX_OPT")
         basis_type_nr = aux_opt_basis
      CASE DEFAULT
         basis_type_nr = unknown_basis
      END SELECT

   END FUNCTION get_basis_type

! **************************************************************************************************
!> \brief ...
!> \param container ...
!> \param basis_set ...
!> \param basis_set_type ...
! **************************************************************************************************
   SUBROUTINE add_basis_set_to_container(container, basis_set, basis_set_type)
      TYPE(basis_set_container_type), DIMENSION(:), &
         INTENT(inout)                                   :: container
      TYPE(gto_basis_set_type), POINTER                  :: basis_set
      CHARACTER(len=*)                                   :: basis_set_type

      INTEGER                                            :: i
      LOGICAL                                            :: success

      success = .FALSE.
      DO i = 1, SIZE(container)
         IF (container(i)%basis_type_nr == 0) THEN
            container(i)%basis_type = basis_set_type
            container(i)%basis_set => basis_set
            container(i)%basis_type_nr = get_basis_type(basis_set_type)
            success = .TRUE.
            EXIT
         END IF
      END DO
      CPASSERT(success)

   END SUBROUTINE add_basis_set_to_container

! **************************************************************************************************
!> \brief ...
!> \param container ...
!> \param inum ...
!> \param basis_type ...
! **************************************************************************************************
   SUBROUTINE remove_basis_from_container(container, inum, basis_type)
      TYPE(basis_set_container_type), DIMENSION(:), &
         INTENT(inout)                                   :: container
      INTEGER, INTENT(IN), OPTIONAL                      :: inum
      CHARACTER(len=*), OPTIONAL                         :: basis_type

      INTEGER                                            :: basis_nr, i, ibas

      IF (PRESENT(inum)) THEN
         CPASSERT(inum <= SIZE(container))
         CPASSERT(inum >= 1)
         ibas = inum
      ELSE IF (PRESENT(basis_type)) THEN
         basis_nr = get_basis_type(basis_type)
         ibas = 0
         DO i = 1, SIZE(container)
            IF (container(i)%basis_type_nr == basis_nr) THEN
               ibas = i
               EXIT
            END IF
         END DO
      ELSE
         CPABORT("")
      END IF
      !
      IF (ibas /= 0) THEN
         container(ibas)%basis_type = ""
         container(ibas)%basis_type_nr = 0
         IF (ASSOCIATED(container(ibas)%basis_set)) THEN
            CALL deallocate_gto_basis_set(container(ibas)%basis_set)
         END IF
      END IF
      ! shift other basis sets
      DO i = ibas + 1, SIZE(container)
         IF (container(i)%basis_type_nr == 0) CYCLE
         container(i - 1)%basis_type = container(i)%basis_type
         container(i - 1)%basis_set => container(i)%basis_set
         container(i - 1)%basis_type_nr = container(i)%basis_type_nr
         container(i)%basis_type = ""
         container(i)%basis_type_nr = 0
         NULLIFY (container(i)%basis_set)
      END DO

   END SUBROUTINE remove_basis_from_container

! **************************************************************************************************
!> \brief Retrieve a basis set from the container
!> \param container ...
!> \param basis_set ...
!> \param inumbas ...
!> \param basis_type ...
! **************************************************************************************************
   SUBROUTINE get_basis_from_container(container, basis_set, inumbas, basis_type)
      TYPE(basis_set_container_type), DIMENSION(:), &
         INTENT(inout)                                   :: container
      TYPE(gto_basis_set_type), POINTER                  :: basis_set
      INTEGER, OPTIONAL                                  :: inumbas
      CHARACTER(len=*), OPTIONAL                         :: basis_type

      INTEGER                                            :: basis_nr, i

      IF (PRESENT(inumbas)) THEN
         CPASSERT(inumbas <= SIZE(container))
         CPASSERT(inumbas >= 1)
         basis_set => container(inumbas)%basis_set
         IF (PRESENT(basis_type)) THEN
            basis_type = container(inumbas)%basis_type
         END IF
      ELSE IF (PRESENT(basis_type)) THEN
         NULLIFY (basis_set)
         basis_nr = get_basis_type(basis_type)
         DO i = 1, SIZE(container)
            IF (container(i)%basis_type_nr == basis_nr) THEN
               basis_set => container(i)%basis_set
               EXIT
            END IF
         END DO
      ELSE
         CPABORT("")
      END IF

   END SUBROUTINE get_basis_from_container
! **************************************************************************************************

END MODULE basis_set_container_types
