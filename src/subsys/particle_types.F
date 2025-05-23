!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Define the data structure for the particle information.
!> \par History
!>      - Atomic kind added in particle_type (MK,08.01.2002)
!>      - Functionality for particle_type added (MK,14.01.2002)
!>      - Allow for general coordinate input (MK,13.09.2003)
!>      - Molecule concept introduced (MK,26.09.2003)
!>      - Last atom information added (jgh,23.05.2004)
!>      - particle_type cleaned (MK,03.02.2005)
!> \author CJM, MK
! **************************************************************************************************
MODULE particle_types
   USE atomic_kind_types,               ONLY: atomic_kind_type
   USE kinds,                           ONLY: dp
   USE message_passing,                 ONLY: mp_comm_type,&
                                              mp_sum
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   ! Global parameters (in this module)

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'particle_types'

   ! Data types
! **************************************************************************************************
   TYPE particle_type
      TYPE(atomic_kind_type), POINTER       :: atomic_kind => Null() ! atomic kind information
      REAL(KIND=dp), DIMENSION(3)           :: f = 0.0_dp, & ! force
                                               r = 0.0_dp, & ! position
                                               v = 0.0_dp ! velocity
      ! Particle dependent terms for shell-model
      INTEGER                               :: atom_index = -1, &
                                               t_region_index = -1, &
                                               shell_index = -1
   END TYPE particle_type

   ! Public data types

   PUBLIC :: particle_type

   ! Public subroutines

   PUBLIC :: allocate_particle_set, &
             deallocate_particle_set, &
             update_particle_set, &
             update_particle_pos_or_vel, &
             get_particle_pos_or_vel

CONTAINS

! **************************************************************************************************
!> \brief   Allocate a particle set.
!> \param particle_set ...
!> \param nparticle ...
!> \date    14.01.2002
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE allocate_particle_set(particle_set, nparticle)
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      INTEGER, INTENT(IN)                                :: nparticle

      INTEGER                                            :: iparticle

      IF (ASSOCIATED(particle_set)) THEN
         CALL deallocate_particle_set(particle_set)
      END IF
      ALLOCATE (particle_set(nparticle))

      DO iparticle = 1, nparticle
         NULLIFY (particle_set(iparticle)%atomic_kind)
         particle_set(iparticle)%f(:) = 0.0_dp
         particle_set(iparticle)%r(:) = 0.0_dp
         particle_set(iparticle)%v(:) = 0.0_dp
         particle_set(iparticle)%shell_index = 0
         particle_set(iparticle)%atom_index = 0
         particle_set(iparticle)%t_region_index = 0
      END DO

   END SUBROUTINE allocate_particle_set

! **************************************************************************************************
!> \brief   Deallocate a particle set.
!> \param particle_set ...
!> \date    14.01.2002
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE deallocate_particle_set(particle_set)
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set

      IF (ASSOCIATED(particle_set)) THEN
         DEALLOCATE (particle_set)
      ELSE
         CALL cp_abort(__LOCATION__, &
                       "The pointer particle_set is not associated and "// &
                       "cannot be deallocated")
      END IF

   END SUBROUTINE deallocate_particle_set

! **************************************************************************************************
!> \brief ...
!> \param particle_set ...
!> \param int_group ...
!> \param pos ...
!> \param vel ...
!> \param for ...
!> \param add ...
! **************************************************************************************************
   SUBROUTINE update_particle_set(particle_set, int_group, pos, vel, for, add)

      TYPE(particle_type), INTENT(INOUT)                 :: particle_set(:)
      TYPE(mp_comm_type), INTENT(IN)                     :: int_group
      REAL(KIND=dp), INTENT(INOUT), OPTIONAL             :: pos(:, :), vel(:, :), for(:, :)
      LOGICAL, INTENT(IN), OPTIONAL                      :: add

      CHARACTER(len=*), PARAMETER :: routineN = 'update_particle_set'

      INTEGER                                            :: handle, iparticle, nparticle
      LOGICAL                                            :: my_add, update_for, update_pos, &
                                                            update_vel

      CALL timeset(routineN, handle)

      nparticle = SIZE(particle_set)
      update_pos = PRESENT(pos)
      update_vel = PRESENT(vel)
      update_for = PRESENT(for)
      my_add = .FALSE.
      IF (PRESENT(add)) my_add = add

      IF (update_pos) THEN
         CALL mp_sum(pos, int_group)
         IF (my_add) THEN
            DO iparticle = 1, nparticle
               particle_set(iparticle)%r(:) = particle_set(iparticle)%r(:) + pos(:, iparticle)
            END DO
         ELSE
            DO iparticle = 1, nparticle
               particle_set(iparticle)%r(:) = pos(:, iparticle)
            END DO
         END IF
      END IF
      IF (update_vel) THEN
         CALL mp_sum(vel, int_group)
         IF (my_add) THEN
            DO iparticle = 1, nparticle
               particle_set(iparticle)%v(:) = particle_set(iparticle)%v(:) + vel(:, iparticle)
            END DO
         ELSE
            DO iparticle = 1, nparticle
               particle_set(iparticle)%v(:) = vel(:, iparticle)
            END DO
         END IF
      END IF
      IF (update_for) THEN
         CALL mp_sum(for, int_group)
         IF (my_add) THEN
            DO iparticle = 1, nparticle
               particle_set(iparticle)%f(:) = particle_set(iparticle)%f(:) + for(:, iparticle)
            END DO
         ELSE
            DO iparticle = 1, nparticle
               particle_set(iparticle)%f(:) = for(:, iparticle)
            END DO
         END IF
      END IF

      CALL timestop(handle)

   END SUBROUTINE update_particle_set

! **************************************************************************************************
!> \brief   Return the atomic position or velocity of atom iatom in x from a
!>          packed vector even if core-shell particles are present
!> \param iatom ...
!> \param particle_set ...
!> \param vector ...
!> \return ...
!> \date    25.11.2010
!> \author  Matthias Krack
!> \version 1.0
! **************************************************************************************************
   FUNCTION get_particle_pos_or_vel(iatom, particle_set, vector) RESULT(x)

      INTEGER, INTENT(IN)                                :: iatom
      TYPE(particle_type), DIMENSION(:), INTENT(IN)      :: particle_set
      REAL(KIND=dp), DIMENSION(:), INTENT(IN)            :: vector
      REAL(KIND=dp), DIMENSION(3)                        :: x

      INTEGER                                            :: ic, is
      REAL(KIND=dp)                                      :: fc, fs, mass

      ic = 3*(iatom - 1)
      IF (particle_set(iatom)%shell_index == 0) THEN
         x(1:3) = vector(ic + 1:ic + 3)
      ELSE
         is = 3*(SIZE(particle_set) + particle_set(iatom)%shell_index - 1)
         mass = particle_set(iatom)%atomic_kind%mass
         fc = particle_set(iatom)%atomic_kind%shell%mass_core/mass
         fs = particle_set(iatom)%atomic_kind%shell%mass_shell/mass
         x(1:3) = fc*vector(ic + 1:ic + 3) + fs*vector(is + 1:is + 3)
      END IF

   END FUNCTION get_particle_pos_or_vel

! **************************************************************************************************
!> \brief   Update the atomic position or velocity by x and return the updated
!>          atomic position or velocity in x even if core-shell particles are
!>          present
!> \param iatom ...
!> \param particle_set ...
!> \param x ...
!> \param vector ...
!> \date    26.11.2010
!> \author  Matthias Krack
!> \version 1.0
!> \note    particle-set is not changed, only the positions or velocities in
!>          the packed vector are updated
! **************************************************************************************************
   SUBROUTINE update_particle_pos_or_vel(iatom, particle_set, x, vector)

      INTEGER, INTENT(IN)                                :: iatom
      TYPE(particle_type), DIMENSION(:), INTENT(IN)      :: particle_set
      REAL(KIND=dp), DIMENSION(3), INTENT(INOUT)         :: x
      REAL(KIND=dp), DIMENSION(:), INTENT(INOUT)         :: vector

      INTEGER                                            :: ic, is
      REAL(KIND=dp)                                      :: fc, fs, mass

      ic = 3*(iatom - 1)
      IF (particle_set(iatom)%shell_index == 0) THEN
         vector(ic + 1:ic + 3) = vector(ic + 1:ic + 3) + x(1:3)
         x(1:3) = vector(ic + 1:ic + 3)
      ELSE
         is = 3*(SIZE(particle_set) + particle_set(iatom)%shell_index - 1)
         mass = particle_set(iatom)%atomic_kind%mass
         fc = particle_set(iatom)%atomic_kind%shell%mass_core/mass
         fs = particle_set(iatom)%atomic_kind%shell%mass_shell/mass
         vector(ic + 1:ic + 3) = vector(ic + 1:ic + 3) + x(1:3)
         vector(is + 1:is + 3) = vector(is + 1:is + 3) + x(1:3)
         x(1:3) = fc*vector(ic + 1:ic + 3) + fs*vector(is + 1:is + 3)
      END IF

   END SUBROUTINE update_particle_pos_or_vel

END MODULE particle_types
