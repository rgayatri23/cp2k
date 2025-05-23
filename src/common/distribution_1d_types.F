!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief stores a lists of integer that are local to a processor.
!>      The idea is that these integers represent objects that are distributed
!>      between the different processors.
!>      The ordering is just to make some operation more efficient, logically
!>      these lists are like sets.
!>      Some operations assume that the integers represent a range of values
!>      from 1 to a (not too big) maxval, and that an element is present just
!>      once, and only on a processor (these assumption are marked in the
!>      documentation of such operations).
!>      The concrete task for which this structure was developed was
!>      distributing atoms between the processors.
!> \par History
!>      05.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
MODULE distribution_1d_types

   USE cp_array_utils,                  ONLY: cp_1d_i_p_type
   USE cp_para_env,                     ONLY: cp_para_env_release,&
                                              cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE parallel_rng_types,              ONLY: rng_stream_p_type
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'distribution_1d_types'

   PUBLIC :: distribution_1d_type
   PUBLIC :: distribution_1d_create, distribution_1d_retain, distribution_1d_release

! **************************************************************************************************
   TYPE local_particle_type
      TYPE(rng_stream_p_type), DIMENSION(:), POINTER :: rng
   END TYPE local_particle_type
!***

! **************************************************************************************************
!> \brief structure to store local (to a processor) ordered lists of integers.
!> \param ref_count reference count (see doc/ReferenceCounting.html)
!> \param n_el n_el(i) is number of elements of list(i)
!> \param list list(i) contains an ordered list of integer (the array
!>        might be bigger than n_el(i), but the extra elements should be
!>        ignored)
!> \param para_env the parallel environment underlying the distribution
!> \param listbased_distribution true if each list has its own
!>        distribution
!> \par History
!>      06.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   TYPE distribution_1d_type
      INTEGER :: ref_count
      LOGICAL :: listbased_distribution
      INTEGER, DIMENSION(:), POINTER :: n_el
      TYPE(cp_1d_i_p_type), DIMENSION(:), POINTER :: list
      TYPE(cp_para_env_type), POINTER :: para_env
      TYPE(local_particle_type), DIMENSION(:), POINTER :: local_particle_set
   END TYPE distribution_1d_type

CONTAINS

! **************************************************************************************************
!> \brief creates a local list
!> \param distribution_1d the lists to create
!> \param para_env parallel environment to be used
!> \param listbased_distribution if each list has its own distribution
!>        (defaults to false)
!> \param n_el number of elements in each list (defaults to 0)
!> \param n_lists number of lists to create (defaults to 1, or size(n_el))
!> \par History
!>      05.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE distribution_1d_create(distribution_1d, para_env, listbased_distribution, &
                                     n_el, n_lists)
      TYPE(distribution_1d_type), POINTER                :: distribution_1d
      TYPE(cp_para_env_type), POINTER                    :: para_env
      LOGICAL, INTENT(in), OPTIONAL                      :: listbased_distribution
      INTEGER, DIMENSION(:), INTENT(in), OPTIONAL        :: n_el
      INTEGER, INTENT(in), OPTIONAL                      :: n_lists

      INTEGER                                            :: ilist, my_n_lists, stat

      my_n_lists = 1
      IF (PRESENT(n_el)) my_n_lists = SIZE(n_el)
      IF (PRESENT(n_lists)) my_n_lists = n_lists

      ALLOCATE (distribution_1d)

      distribution_1d%ref_count = 1

      distribution_1d%para_env => para_env
      CALL cp_para_env_retain(para_env)

      NULLIFY (distribution_1d%list, distribution_1d%n_el)

      distribution_1d%listbased_distribution = .FALSE.
      IF (PRESENT(listbased_distribution)) &
         distribution_1d%listbased_distribution = listbased_distribution

      ALLOCATE (distribution_1d%n_el(my_n_lists), distribution_1d%list(my_n_lists), &
                stat=stat)
      CPASSERT(stat == 0)

      IF (PRESENT(n_el)) THEN
         distribution_1d%n_el(1:my_n_lists) = n_el(1:my_n_lists)
         DO ilist = 1, my_n_lists
            ALLOCATE (distribution_1d%list(ilist)%array(n_el(ilist)))
            distribution_1d%list(ilist)%array = -1
         END DO
      ELSE
         distribution_1d%n_el(1:my_n_lists) = 0
         DO ilist = 1, my_n_lists
            NULLIFY (distribution_1d%list(ilist)%array)
         END DO
      END IF

      NULLIFY (distribution_1d%local_particle_set)

   END SUBROUTINE distribution_1d_create

! **************************************************************************************************
!> \brief retains a distribution_1d
!> \param distribution_1d  the object to retain
!> \par History
!>      05.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE distribution_1d_retain(distribution_1d)
      TYPE(distribution_1d_type), POINTER                :: distribution_1d

      CPASSERT(ASSOCIATED(distribution_1d))
      CPASSERT(distribution_1d%ref_count > 0)
      distribution_1d%ref_count = distribution_1d%ref_count + 1
   END SUBROUTINE distribution_1d_retain

! **************************************************************************************************
!> \brief releases the given distribution_1d
!> \param distribution_1d the object to release
!> \par History
!>      05.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE distribution_1d_release(distribution_1d)
      TYPE(distribution_1d_type), POINTER                :: distribution_1d

      INTEGER                                            :: ilist, iparticle_kind, iparticle_local, &
                                                            nparticle_kind, nparticle_local
      TYPE(local_particle_type), DIMENSION(:), POINTER   :: local_particle_set

      IF (ASSOCIATED(distribution_1d)) THEN
         CPASSERT(distribution_1d%ref_count > 0)
         distribution_1d%ref_count = distribution_1d%ref_count - 1
         IF (distribution_1d%ref_count == 0) THEN
            DEALLOCATE (distribution_1d%n_el)

            DO ilist = 1, SIZE(distribution_1d%list)
               DEALLOCATE (distribution_1d%list(ilist)%array)
            END DO
            DEALLOCATE (distribution_1d%list)

            !MK Delete Wiener process

            local_particle_set => distribution_1d%local_particle_set

            IF (ASSOCIATED(local_particle_set)) THEN
               nparticle_kind = SIZE(local_particle_set)
               DO iparticle_kind = 1, nparticle_kind
                  IF (ASSOCIATED(local_particle_set(iparticle_kind)%rng)) THEN
                     nparticle_local = SIZE(local_particle_set(iparticle_kind)%rng)
                     DO iparticle_local = 1, nparticle_local
                        IF (ASSOCIATED(local_particle_set(iparticle_kind)% &
                                       rng(iparticle_local)%stream)) THEN
                           DEALLOCATE (local_particle_set(iparticle_kind)% &
                                       rng(iparticle_local)%stream)
                        END IF
                     END DO
                     DEALLOCATE (local_particle_set(iparticle_kind)%rng)
                  END IF
               END DO
               DEALLOCATE (local_particle_set)
            END IF

            CALL cp_para_env_release(distribution_1d%para_env)

            DEALLOCATE (distribution_1d)
         END IF
      END IF

   END SUBROUTINE distribution_1d_release

END MODULE distribution_1d_types
