!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief wrappers for the actual blacs calls.
!>      all functionality needed in the code should actually be provide by cp_blacs_env
!>      these functions should be private members of that module
!> \note
!>      http://www.netlib.org/blacs/BLACS/QRef.html
!> \par History
!>      12.2003 created [Joost]
!> \author Joost VandeVondele
! **************************************************************************************************
MODULE cp_blacs_calls

   USE kinds,                           ONLY: dp
   USE message_passing,                 ONLY: mp_comm_type
#include "../base/base_uses.f90"

   IMPLICIT NONE
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_blacs_calls'
   PRIVATE
   ! setup / info calls
   PUBLIC :: cp_blacs_gridinit, cp_blacs_set, &
             cp_blacs_gridexit, cp_blacs_gridinfo
   ! actual message passing
   PUBLIC :: cp_blacs_zgebs2d, cp_blacs_zgebr2d, cp_blacs_dgebs2d, &
             cp_blacs_dgebr2d

!***
CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param context ...
!> \param order ...
!> \param nprow ...
!> \param npcol ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_gridinit(context, order, nprow, npcol)
      TYPE(mp_comm_type), INTENT(INOUT) :: context
      CHARACTER(len=1), INTENT(IN):: order
      INTEGER, INTENT(IN)    :: nprow, npcol
#if defined(__SCALAPACK)
      INTEGER :: blacs_handle
      blacs_handle = context%get_handle()
      CALL blacs_gridinit(blacs_handle, order, nprow, npcol)
      CALL context%set_handle(blacs_handle)
#else
      MARK_USED(context)
      MARK_USED(order)
      MARK_USED(nprow)
      MARK_USED(npcol)
#endif
   END SUBROUTINE cp_blacs_gridinit

! **************************************************************************************************
!> \brief ...
!> \param context ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_gridexit(context)
      TYPE(mp_comm_type), INTENT(IN) :: context
#if defined(__SCALAPACK)
      CALL blacs_gridexit(context%get_handle())
#else
      MARK_USED(context)
#endif
   END SUBROUTINE cp_blacs_gridexit

! **************************************************************************************************
!> \brief ...
!> \param context ...
!> \param nprow ...
!> \param npcol ...
!> \param myprow ...
!> \param mypcol ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_gridinfo(context, nprow, npcol, myprow, mypcol)
      TYPE(mp_comm_type), INTENT(IN)  :: context
      INTEGER, INTENT(OUT) :: nprow, npcol, myprow, mypcol
#if defined(__SCALAPACK)
      CALL blacs_gridinfo(context%get_handle(), nprow, npcol, myprow, mypcol)
#else
      MARK_USED(context)
      nprow = 1
      npcol = 1
      myprow = 0
      mypcol = 0
#endif
   END SUBROUTINE cp_blacs_gridinfo

! **************************************************************************************************
!> \brief ...
!> \param context ...
!> \param what :
!>     WHAT = 0 : Handle indicating default system context;  ! DO NOT USE (i.e. use para_env%group)
!>     WHAT = 1 : The BLACS message ID range;
!>     WHAT = 2 : The BLACS debug level the library was compiled with;
!>     WHAT = 10: Handle indicating the system context used to define the BLACS context whose handle is ICONTXT;
!>     WHAT = 11: Number of rings multiring topology is presently using;
!>     WHAT = 12: Number of branches general tree topology is presently using.
!>     WHAT = 15: If non-zero, makes topology choice for repeatable collectives
!> \param val ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_set(context, what, val)
      TYPE(mp_comm_type), INTENT(IN) :: context
      INTEGER, INTENT(IN)  :: what, val
#if defined(__SCALAPACK)
      CALL blacs_set(context, what, val)
#else
      MARK_USED(context)
      MARK_USED(what)
      MARK_USED(val)
#endif
   END SUBROUTINE cp_blacs_set

! **************************************************************************************************
!> \brief ...
!> \param ICONTXT ...
!> \param SCOPE ...
!> \param TOP ...
!> \param M ...
!> \param N ...
!> \param A ...
!> \param LDA ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_zgebs2d(ICONTXT, SCOPE, TOP, M, N, A, LDA)
      TYPE(mp_comm_type), INTENT(IN)     :: ICONTXT
      CHARACTER(len=1), INTENT(IN) :: SCOPE, TOP
      INTEGER, INTENT(IN)     :: M, N, LDA
      COMPLEX(KIND=dp)            :: A
#if defined(__SCALAPACK)
      CALL zgebs2d(ICONTXT%get_handle(), SCOPE, TOP, M, N, A, LDA)
#else
      MARK_USED(ICONTXT)
      MARK_USED(SCOPE)
      MARK_USED(TOP)
      MARK_USED(M)
      MARK_USED(N)
      MARK_USED(A)
      MARK_USED(LDA)
#endif
   END SUBROUTINE
! **************************************************************************************************
!> \brief ...
!> \param ICONTXT ...
!> \param SCOPE ...
!> \param TOP ...
!> \param M ...
!> \param N ...
!> \param A ...
!> \param LDA ...
!> \param RSRC ...
!> \param CSRC ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_zgebr2d(ICONTXT, SCOPE, TOP, M, N, A, LDA, RSRC, CSRC)
      TYPE(mp_comm_type), INTENT(IN)     :: ICONTXT
      CHARACTER(len=1), INTENT(IN) :: SCOPE, TOP
      INTEGER, INTENT(IN)     :: M, N, LDA
      INTEGER, INTENT(IN)     :: RSRC, CSRC
      COMPLEX(KIND=dp)            :: A
#if defined(__SCALAPACK)
      CALL zgebr2d(ICONTXT%get_handle(), SCOPE, TOP, M, N, A, LDA, RSRC, CSRC)
#else
      MARK_USED(ICONTXT)
      MARK_USED(SCOPE)
      MARK_USED(TOP)
      MARK_USED(M)
      MARK_USED(N)
      MARK_USED(A)
      MARK_USED(LDA)
      MARK_USED(RSRC)
      MARK_USED(CSRC)
#endif
   END SUBROUTINE

! **************************************************************************************************
!> \brief ...
!> \param ICONTXT ...
!> \param SCOPE ...
!> \param TOP ...
!> \param M ...
!> \param N ...
!> \param A ...
!> \param LDA ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_dgebs2d(ICONTXT, SCOPE, TOP, M, N, A, LDA)
      TYPE(mp_comm_type), INTENT(IN)     :: ICONTXT
      CHARACTER(len=1), INTENT(IN) :: SCOPE, TOP
      INTEGER, INTENT(IN)     :: M, N, LDA
      REAL(KIND=dp)               :: A
#if defined(__SCALAPACK)
      CALL dgebs2d(ICONTXT%get_handle(), SCOPE, TOP, M, N, A, LDA)
#else
      MARK_USED(ICONTXT)
      MARK_USED(SCOPE)
      MARK_USED(TOP)
      MARK_USED(M)
      MARK_USED(N)
      MARK_USED(A)
      MARK_USED(LDA)
#endif
   END SUBROUTINE
! **************************************************************************************************
!> \brief ...
!> \param ICONTXT ...
!> \param SCOPE ...
!> \param TOP ...
!> \param M ...
!> \param N ...
!> \param A ...
!> \param LDA ...
!> \param RSRC ...
!> \param CSRC ...
! **************************************************************************************************
   SUBROUTINE cp_blacs_dgebr2d(ICONTXT, SCOPE, TOP, M, N, A, LDA, RSRC, CSRC)
      TYPE(mp_comm_type), INTENT(IN)     :: ICONTXT
      CHARACTER(len=1), INTENT(IN) :: SCOPE, TOP
      INTEGER, INTENT(IN)     :: M, N, LDA
      INTEGER, INTENT(IN)     :: RSRC, CSRC
      REAL(KIND=dp)               :: A
#if defined(__SCALAPACK)
      CALL dgebr2d(ICONTXT%get_handle(), SCOPE, TOP, M, N, A, LDA, RSRC, CSRC)
#else
      MARK_USED(ICONTXT)
      MARK_USED(SCOPE)
      MARK_USED(TOP)
      MARK_USED(M)
      MARK_USED(N)
      MARK_USED(A)
      MARK_USED(LDA)
      MARK_USED(RSRC)
      MARK_USED(CSRC)
#endif
   END SUBROUTINE

END MODULE cp_blacs_calls
