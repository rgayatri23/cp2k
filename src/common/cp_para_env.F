!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief type to store parallelization informations (at the moment assumes 1d
!>      position and uses mpi)
!> \par History
!>      07.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
MODULE cp_para_env
   USE cp_para_types,                   ONLY: cp_para_cart_type,&
                                              cp_para_env_type
   USE message_passing,                 ONLY: mp_comm_free,&
                                              mp_comm_split_direct,&
                                              mp_comm_type,&
                                              mp_environ
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_para_env'

   PUBLIC :: cp_para_env_retain, cp_para_env_release, cp_para_env_create, cp_para_env_split
   PUBLIC :: cp_cart_create, cp_cart_release
!***
CONTAINS

! **************************************************************************************************
!> \brief creates a new para environment
!> \param para_env the new parallel environment
!> \param group the id of the actual mpi_group
!> \param source the id of the special (master) processor (defaults to 0)
!> \param mepos the id of the actual processor
!> \param num_pe the number of processors in the group
!> \param owns_group if the group is owned by this object (defaults to true)
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE cp_para_env_create(para_env, group, source, mepos, num_pe, &
                                 owns_group)
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(mp_comm_type), INTENT(in)                     :: group
      INTEGER, INTENT(in), OPTIONAL                      :: source, mepos, num_pe
      LOGICAL, INTENT(in), OPTIONAL                      :: owns_group

      CPASSERT(.NOT. ASSOCIATED(para_env))
      ALLOCATE (para_env)
      para_env%group = group
      para_env%source = 0
      para_env%ref_count = 1
      para_env%owns_group = .TRUE.
      IF (PRESENT(source)) para_env%source = source
      IF (PRESENT(owns_group)) para_env%owns_group = owns_group
      IF (.NOT. (PRESENT(mepos) .AND. PRESENT(num_pe))) THEN
         CALL mp_environ(taskid=para_env%mepos, numtask=para_env%num_pe, group=group)
      ELSE
         para_env%mepos = mepos
         para_env%num_pe = num_pe
      END IF
      para_env%ionode = para_env%mepos == para_env%source
   END SUBROUTINE cp_para_env_create

! **************************************************************************************************
!> \brief retains the para object (to be called when you want to keep a
!>      shared copy of this object)
!> \param para_env the new group
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE cp_para_env_retain(para_env)
      TYPE(cp_para_env_type), INTENT(IN), POINTER        :: para_env

      CPASSERT(ASSOCIATED(para_env))
      CPASSERT(para_env%ref_count > 0)
      para_env%ref_count = para_env%ref_count + 1
   END SUBROUTINE cp_para_env_retain

! **************************************************************************************************
!> \brief splits the communicator of the template para_env according to the provided color
!> \param para_env para_env with new sub communicator
!> \param para_env_template para_env to be split
!> \param color all processes with same color will belong to the same sub communicator
! **************************************************************************************************
   SUBROUTINE cp_para_env_split(para_env, para_env_template, color)
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_para_env_type), INTENT(IN)                 :: para_env_template
      INTEGER, INTENT(IN)                                :: color

      TYPE(mp_comm_type)                                 :: comm

      CPASSERT(para_env_template%ref_count > 0)
      CALL mp_comm_split_direct(para_env_template%group, comm, color)
      NULLIFY (para_env)
      CALL cp_para_env_create(para_env, comm)

   END SUBROUTINE cp_para_env_split

! **************************************************************************************************
!> \brief releases the para object (to be called when you don't want anymore
!>      the shared copy of this object)
!> \param para_env the new group
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
!> \note
!>      to avoid circular dependencies cp_log_handling has a private copy
!>      of this method (see cp_log_handling:my_cp_para_env_release)!
! **************************************************************************************************
   SUBROUTINE cp_para_env_release(para_env)
      TYPE(cp_para_env_type), POINTER                    :: para_env

      IF (ASSOCIATED(para_env)) THEN
         CPASSERT(para_env%ref_count > 0)
         para_env%ref_count = para_env%ref_count - 1
         IF (para_env%ref_count < 1) THEN
            IF (para_env%owns_group) THEN
               CALL mp_comm_free(para_env%group)
            END IF
            DEALLOCATE (para_env)
         END IF
      END IF
      NULLIFY (para_env)
   END SUBROUTINE cp_para_env_release

! **************************************************************************************************
!> \brief creates a cart (multidimensional parallel environment)
!> \param cart the cart environment to create
!> \param group the mpi communicator
!> \param ndims the number of dimensions of the cart
!> \param owns_group if this object owns the underlying cart (and should
!>        free it)
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE cp_cart_create(cart, group, ndims, owns_group)
      TYPE(cp_para_cart_type), POINTER                   :: cart
      TYPE(mp_comm_type), INTENT(in)                     :: group
      INTEGER, INTENT(in)                                :: ndims
      LOGICAL, INTENT(in), OPTIONAL                      :: owns_group

      CPASSERT(.NOT. ASSOCIATED(cart))
      ALLOCATE (cart)
      cart%owns_group = .TRUE.
      IF (PRESENT(owns_group)) cart%owns_group = owns_group
      cart%ndims = ndims
      cart%group = group

      ALLOCATE (cart%source(ndims), cart%periodic(ndims), cart%mepos(ndims), &
                cart%num_pe(ndims))

      cart%source = 0
      cart%mepos = 0
      cart%periodic = .FALSE.
      cart%ref_count = 1
      cart%ntask = 1
      CALL cp_cart_update(cart)
   END SUBROUTINE cp_cart_create

! **************************************************************************************************
!> \brief updates the information about the given cart
!> \param cart the cart to update
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE cp_cart_update(cart)
      TYPE(cp_para_cart_type), INTENT(INOUT)             :: cart

      CPASSERT(cart%ref_count > 0)
      CALL mp_environ(cart%group, cart%ndims, cart%num_pe, task_coor=cart%mepos, &
                      periods=cart%periodic)
      CALL mp_environ(numtask=cart%ntask, taskid=cart%rank, group=cart%group)
   END SUBROUTINE cp_cart_update

! **************************************************************************************************
!> \brief releases the given cart
!> \param cart the cart to release
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE cp_cart_release(cart)
      TYPE(cp_para_cart_type), POINTER                   :: cart

      IF (ASSOCIATED(cart)) THEN
         CPASSERT(cart%ref_count > 0)
         cart%ref_count = cart%ref_count - 1
         IF (cart%ref_count == 0) THEN
            IF (cart%owns_group) THEN
               CALL mp_comm_free(cart%group)
            END IF
            DEALLOCATE (cart%source, cart%periodic, cart%mepos, cart%num_pe)
            DEALLOCATE (cart)
         END IF
      END IF
      NULLIFY (cart)
   END SUBROUTINE cp_cart_release

END MODULE cp_para_env
