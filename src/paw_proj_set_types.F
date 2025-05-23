!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \par History
!>      none
!> \author MI (08.01.2004)
! **************************************************************************************************
MODULE paw_proj_set_types

   USE ao_util,                         ONLY: exp_radius,&
                                              gauss_exponent
   USE basis_set_types,                 ONLY: get_gto_basis_set,&
                                              gto_basis_set_type
   USE cp_control_types,                ONLY: qs_control_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE input_section_types,             ONLY: section_vals_type
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE mathconstants,                   ONLY: dfac,&
                                              pi,&
                                              rootpi
   USE mathlib,                         ONLY: invert_matrix
   USE memory_utilities,                ONLY: reallocate
   USE orbital_pointers,                ONLY: indco,&
                                              indso,&
                                              nco,&
                                              ncoset,&
                                              nso,&
                                              nsoset
   USE orbital_transformation_matrices, ONLY: orbtramat
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   ! Global parameters (only in this module)

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'paw_proj_set_types'

   INTEGER, PARAMETER :: max_name_length = 60

   ! Define the projector types

   TYPE paw_proj_set_type
      INTEGER                                            :: maxl, ncgauprj, nsgauprj
      INTEGER, DIMENSION(:), POINTER                     :: nprj ! 0:maxl
      INTEGER, DIMENSION(:), POINTER                     :: lx, ly, lz ! ncgauprj
      INTEGER, DIMENSION(:), POINTER                     :: ll, m ! nsgauprj
      INTEGER, DIMENSION(:), POINTER                     :: first_prj, last_prj ! 0:maxl
      INTEGER, DIMENSION(:), POINTER                     :: first_prjs ! 0:maxl
      REAL(KIND=dp)                                      :: rcprj
      REAL(KIND=dp), DIMENSION(:), POINTER               :: zisomin, zprjisomin
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: zetprj ! maxnprj,0:maxl
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: rzetprj ! maxnprj,0:maxl
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: cprj ! ncgauprj, maxco*nset
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: cprj_s ! nsgauprj, maxso*nset
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: csprj ! ncgauprj, np_so
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: local_oce_cphi_h, local_oce_cphi_s ! maxco,ncgf
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: local_oce_sphi_h, local_oce_sphi_s ! maxco,nsgf
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: sphi_h, sphi_s
      REAL(KIND=dp), DIMENSION(:, :, :, :), POINTER      :: gccprj ! maxnprj,maxnpgf,0:maxl,nset
      LOGICAL, DIMENSION(:, :), POINTER                  :: isoprj ! maxnprj,0:maxl
      INTEGER                                            :: nsatbas
      INTEGER                                            :: nsotot
      INTEGER, DIMENSION(:), POINTER                     :: o2nindex ! maxso*nset
      INTEGER, DIMENSION(:), POINTER                     :: n2oindex ! maxso*nset

   END TYPE paw_proj_set_type

   ! Public subroutines

   PUBLIC ::  allocate_paw_proj_set, &
             deallocate_paw_proj_set, &
             get_paw_proj_set, &
             projectors, &
             set_paw_proj_set

   ! Public data types

   PUBLIC ::  paw_proj_set_type

CONTAINS

! **************************************************************************************************
!> \brief   Allocate projector type for GAPW
!> \param paw_proj_set ...
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE allocate_paw_proj_set(paw_proj_set)

      TYPE(paw_proj_set_type), POINTER                   :: paw_proj_set

      IF (ASSOCIATED(paw_proj_set)) CALL deallocate_paw_proj_set(paw_proj_set)

      ALLOCATE (paw_proj_set)

      NULLIFY (paw_proj_set%nprj)
      NULLIFY (paw_proj_set%lx)
      NULLIFY (paw_proj_set%ly)
      NULLIFY (paw_proj_set%lz)
      NULLIFY (paw_proj_set%ll)
      NULLIFY (paw_proj_set%m)
      NULLIFY (paw_proj_set%first_prj)
      NULLIFY (paw_proj_set%last_prj)
      NULLIFY (paw_proj_set%first_prjs)

      NULLIFY (paw_proj_set%zisomin)
      NULLIFY (paw_proj_set%zprjisomin)
      NULLIFY (paw_proj_set%zetprj)
      NULLIFY (paw_proj_set%cprj)
      NULLIFY (paw_proj_set%cprj_s)
      NULLIFY (paw_proj_set%csprj)
      NULLIFY (paw_proj_set%local_oce_cphi_h)
      NULLIFY (paw_proj_set%local_oce_cphi_s)
      NULLIFY (paw_proj_set%local_oce_sphi_h)
      NULLIFY (paw_proj_set%local_oce_sphi_s)
      NULLIFY (paw_proj_set%sphi_h)
      NULLIFY (paw_proj_set%sphi_s)
      NULLIFY (paw_proj_set%gccprj)
      NULLIFY (paw_proj_set%rzetprj)

      NULLIFY (paw_proj_set%isoprj)

      NULLIFY (paw_proj_set%o2nindex)
      NULLIFY (paw_proj_set%n2oindex)

   END SUBROUTINE allocate_paw_proj_set

! **************************************************************************************************
!> \brief   Deallocate a projector-type set data set.
!> \param paw_proj_set ...
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE deallocate_paw_proj_set(paw_proj_set)
      TYPE(paw_proj_set_type), POINTER                   :: paw_proj_set

      DEALLOCATE (paw_proj_set%zisomin)
      DEALLOCATE (paw_proj_set%zprjisomin)
      DEALLOCATE (paw_proj_set%nprj)
      DEALLOCATE (paw_proj_set%lx)
      DEALLOCATE (paw_proj_set%ly)
      DEALLOCATE (paw_proj_set%lz)
      DEALLOCATE (paw_proj_set%ll)
      DEALLOCATE (paw_proj_set%m)
      DEALLOCATE (paw_proj_set%first_prj)
      DEALLOCATE (paw_proj_set%last_prj)
      DEALLOCATE (paw_proj_set%first_prjs)
      DEALLOCATE (paw_proj_set%zetprj)
      DEALLOCATE (paw_proj_set%cprj)
      DEALLOCATE (paw_proj_set%cprj_s)
      DEALLOCATE (paw_proj_set%csprj)
      DEALLOCATE (paw_proj_set%local_oce_cphi_h)
      DEALLOCATE (paw_proj_set%local_oce_cphi_s)
      DEALLOCATE (paw_proj_set%local_oce_sphi_h)
      DEALLOCATE (paw_proj_set%local_oce_sphi_s)
      DEALLOCATE (paw_proj_set%sphi_h)
      DEALLOCATE (paw_proj_set%sphi_s)
      DEALLOCATE (paw_proj_set%gccprj)
      DEALLOCATE (paw_proj_set%isoprj)
      DEALLOCATE (paw_proj_set%rzetprj)
      DEALLOCATE (paw_proj_set%o2nindex)
      DEALLOCATE (paw_proj_set%n2oindex)

      DEALLOCATE (paw_proj_set)
   END SUBROUTINE deallocate_paw_proj_set

! **************************************************************************************************
!> \brief   Initialize the projector-type set data set.
!> \param paw_proj ...
!> \param orb_basis ...
!> \param rc ...
!> \param qs_control ...
!> \param max_rad_local_type ...
!> \param force_env_section ...
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE projectors(paw_proj, orb_basis, rc, qs_control, max_rad_local_type, &
                         force_env_section)

      TYPE(paw_proj_set_type), POINTER                   :: paw_proj
      TYPE(gto_basis_set_type), POINTER                  :: orb_basis
      REAL(KIND=dp)                                      :: rc
      TYPE(qs_control_type), INTENT(IN)                  :: qs_control
      REAL(KIND=dp), INTENT(IN)                          :: max_rad_local_type
      TYPE(section_vals_type), POINTER                   :: force_env_section

      REAL(KIND=dp)                                      :: eps_fit, eps_iso, eps_orb, eps_svd, &
                                                            max_rad_local

      eps_fit = qs_control%gapw_control%eps_fit
      eps_iso = qs_control%gapw_control%eps_iso
      eps_svd = qs_control%gapw_control%eps_svd
      max_rad_local = qs_control%gapw_control%max_rad_local
      IF (max_rad_local_type .LT. max_rad_local) THEN
         max_rad_local = max_rad_local_type
      END IF
      eps_orb = qs_control%eps_pgf_orb

      CALL build_projector(paw_proj, orb_basis, eps_fit, eps_iso, eps_svd, &
                           rc, eps_orb, max_rad_local, force_env_section)

   END SUBROUTINE projectors

! **************************************************************************************************
!> \brief   initialize the projector-type set data set.
!> \param paw_proj ...
!> \param orb_basis ...
!> \param eps_fit ...
!> \param eps_iso ...
!> \param eps_svd ...
!> \param rc ...
!> \param eps_orb ...
!> \param max_rad_local ...
!> \param force_env_section ...
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE build_projector(paw_proj, orb_basis, eps_fit, eps_iso, eps_svd, &
                              rc, eps_orb, max_rad_local, force_env_section)

      TYPE(paw_proj_set_type), POINTER                   :: paw_proj
      TYPE(gto_basis_set_type), POINTER                  :: orb_basis
      REAL(KIND=dp), INTENT(IN)                          :: eps_fit, eps_iso, eps_svd, rc, eps_orb, &
                                                            max_rad_local
      TYPE(section_vals_type), POINTER                   :: force_env_section

      CHARACTER(LEN=default_string_length)               :: bsname
      INTEGER :: ic, icgf, icgfmax, icgfmin, ico, icomax, icomin, il, info, ip, ipgf, ipp, iprj, &
         iprjfirst, iprjs, is, iset, isgf, isgfmax, isgfmin, ishell, iso, iso_pgf, iso_set, &
         isomin, jp, k, kp, lshell, lwork, lx, ly, lz, maxco, maxl, maxnprj, maxpgf, maxso, mp, &
         ms, n, ncgauprj, ncgf, nisop, notprj, np, npgfg, ns, nset, nsgauprj, nsgf, nsox, &
         output_unit
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: IWORK
      INTEGER, DIMENSION(:), POINTER                     :: lmax, lmin, npgf, nshell
      INTEGER, DIMENSION(:, :), POINTER                  :: first_cgf, first_sgf, l, last_cgf, &
                                                            last_sgf
      LOGICAL, ALLOCATABLE, DIMENSION(:)                 :: isoprj
      REAL(KIND=dp)                                      :: expzet, my_error, prefac, radius, x, &
                                                            zetmin, zetval
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:)           :: S, Work_dgesdd
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: U, VT
      REAL(KIND=dp), DIMENSION(:), POINTER               :: set_radius, zet, zetp
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: cphi, gcc, smat, sphi, work
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER         :: gcca, set_radius2
      TYPE(cp_logger_type), POINTER                      :: logger

      NULLIFY (logger)
      logger => cp_get_default_logger()

      NULLIFY (first_cgf, first_sgf, last_cgf, last_sgf, gcc, l, set_radius, set_radius2)
      NULLIFY (cphi, sphi, lmax, lmin, npgf, nshell, zet, zetp, smat, work, gcca)

      CPASSERT(ASSOCIATED(paw_proj))
      CPASSERT(ASSOCIATED(orb_basis))

      CALL get_gto_basis_set(gto_basis_set=orb_basis, name=bsname, &
                             ncgf=ncgf, nset=nset, nsgf=nsgf, &
                             lmax=lmax, lmin=lmin, npgf=npgf, &
                             nshell=nshell, cphi=cphi, sphi=sphi, &
                             first_cgf=first_cgf, first_sgf=first_sgf, &
                             l=l, last_cgf=last_cgf, last_sgf=last_sgf, &
                             maxco=maxco, maxso=maxso, maxl=maxl, maxpgf=maxpgf, &
                             gcc=gcca)

      paw_proj%maxl = maxl
      CPASSERT(.NOT. ASSOCIATED(paw_proj%zisomin))
      CPASSERT(.NOT. ASSOCIATED(paw_proj%zprjisomin))
      CPASSERT(.NOT. ASSOCIATED(paw_proj%nprj))

      ALLOCATE (paw_proj%zisomin(0:maxl))
      paw_proj%zisomin(0:maxl) = 0.0_dp
      ALLOCATE (paw_proj%zprjisomin(0:maxl))
      paw_proj%zprjisomin(0:maxl) = 0.0_dp
      ALLOCATE (paw_proj%nprj(0:maxl))
      paw_proj%nprj(0:maxl) = 0

      output_unit = cp_print_key_unit_nr(logger, force_env_section, &
                                         "DFT%PRINT%GAPW%PROJECTORS", extension=".Log")

      IF (output_unit > 0) THEN
         WRITE (UNIT=output_unit, FMT="(/,T2,A)") &
            "Projectors for the basis functions of "//TRIM(bsname)
      END IF

      ALLOCATE (set_radius(nset))
      set_radius = 0.0_dp
      DO iset = 1, nset
         DO is = 1, nshell(iset)
            set_radius(iset) = MAX(set_radius(iset), &
                                   exp_radius(l(is, iset), orb_basis%zet(npgf(iset), iset), &
                                              eps_orb, gcca(npgf(iset), is, iset), &
                                              rlow=set_radius(iset)))
         END DO ! is
      END DO ! iset

      ALLOCATE (set_radius2(maxpgf, 0:maxl, nset))
      set_radius2 = 0.0_dp
      DO iset = 1, nset
         DO lshell = lmin(iset), lmax(iset)
            DO ip = 1, npgf(iset)
               set_radius2(ip, lshell, iset) = &
                  exp_radius(lshell, orb_basis%zet(ip, iset), eps_orb, 1.0_dp)
            END DO
         END DO ! is
      END DO ! iset

      maxnprj = 0
      DO lshell = 0, maxl ! lshell
         np = 0
         DO iset = 1, nset
            IF (lshell >= lmin(iset) .AND. lshell <= lmax(iset)) THEN
               DO ip = 1, npgf(iset)
                  IF (set_radius2(ip, lshell, iset) < max_rad_local) THEN
                     np = np + 1
                  END IF
               END DO
            END IF
         END DO
         maxnprj = MAX(maxnprj, np)
         paw_proj%nprj(lshell) = np
      END DO ! lshell

      ! Allocate exponents and coefficients
      ALLOCATE (paw_proj%zetprj(maxnprj, 0:maxl))
      paw_proj%zetprj(1:maxnprj, 0:maxl) = 0.0_dp
      ALLOCATE (paw_proj%gccprj(maxnprj, maxpgf, 0:maxl, nset))
      paw_proj%gccprj = 0.0_dp
      ALLOCATE (paw_proj%rzetprj(maxnprj, 0:maxl))
      paw_proj%rzetprj(1:maxnprj, 0:maxl) = 0.0_dp
      ALLOCATE (paw_proj%isoprj(maxnprj, 0:maxl))
      paw_proj%isoprj = .FALSE.

      mp = 0
      DO lshell = 0, maxl ! lshell
         mp = MAX(mp, paw_proj%nprj(lshell)*nco(lshell))
      END DO

      NULLIFY (zet, zetp, gcc, smat, work)
      ! Generate the projetor basis for each ang. mom. q.n.
      DO lshell = 0, maxl ! lshell

         np = paw_proj%nprj(lshell)

         ALLOCATE (isoprj(np))
         isoprj = .FALSE.

         ALLOCATE (zet(np), zetp(np), gcc(np, np), smat(np, np), work(np, np))

         zet(:) = 0.0_dp
         zetp(:) = 0.0_dp
         gcc(:, :) = 0.0_dp
         smat(:, :) = 0.0_dp
         work(:, :) = 0.0_dp

         npgfg = 0
         notprj = 0
         ! Collect all the exponent which contribute to lshell
         DO iset = 1, nset ! iset
            IF (lshell >= lmin(iset) .AND. lshell <= lmax(iset)) THEN
               DO ip = 1, npgf(iset)
                  IF (set_radius2(ip, lshell, iset) < max_rad_local) THEN
                     npgfg = npgfg + 1
                     zet(npgfg) = orb_basis%zet(ip, iset)
                  ELSE
                     notprj = notprj + 1
                  END IF
               END DO
            END IF
         END DO ! iset

         !     *** Smallest exp. due to eps_iso: concerned as an isolated projector ***
         paw_proj%zisomin(lshell) = gauss_exponent(lshell, rc, eps_iso, 1.0_dp)

         nisop = 0
         DO ip = 1, np
            ! Check for equal exponents
            DO ipp = 1, ip - 1
               IF (zet(ip) == zet(ipp)) THEN
                  CALL cp_abort(__LOCATION__, &
                                "Linear dependency in the construction of the GAPW projectors:"// &
                                " different sets of the BASIS SET contain identical exponents")
               END IF
            END DO

            IF (zet(ip) >= paw_proj%zisomin(lshell)) THEN
               isoprj(ip) = .TRUE.
               nisop = nisop + 1
            ELSE
               isoprj(ip) = .FALSE.
            END IF
         END DO

         ! Smallest exp. due to eps_fit: where to start geometric progression
         zetmin = gauss_exponent(lshell, rc, eps_fit, 1.0_dp)

         ! Generate the projectors by the geometric progression

         IF (np - nisop - 1 > 2) THEN
            x = (80.0_dp/zetmin)**(1.0_dp/REAL(np - nisop - 1, dp))
         ELSE
            x = 2.0_dp
         END IF
         IF (x > 2.0_dp) x = 2.0_dp

         zetval = zetmin
         DO ip = np, 1, -1
            IF (.NOT. isoprj(ip)) THEN
               zetp(ip) = zetval
               zetval = x*zetval
            END IF
         END DO

         paw_proj%zprjisomin(lshell) = zetval

         nisop = 0
         DO ip = np, 1, -1
            IF (isoprj(ip)) THEN
               zetp(ip) = zetval
               zetval = x*zetval
               nisop = nisop + 1
            END IF
         END DO

         !     *** Build the overlap matrix: <projector|primitive> ***
         prefac = 0.5_dp**(lshell + 2)*rootpi*dfac(2*lshell + 1)
         expzet = REAL(lshell, dp) + 1.5_dp

         DO ip = 1, np
            IF (isoprj(ip)) THEN
               smat(ip, ip) = prefac/(zetp(ip) + zet(ip))**expzet
            ELSE
               DO jp = 1, np
                  IF (.NOT. isoprj(jp)) THEN
                     smat(ip, jp) = prefac/(zetp(ip) + zet(jp))**expzet
                  END IF
               END DO
            END IF
         END DO

         !FIXME ... catch the case where np == 0
         CPASSERT(np > 0)

         ! Compute inverse of the transpose
         IF (eps_svd .EQ. 0.0_dp) THEN
            CALL invert_matrix(smat, gcc, my_error, "T")
         ELSE
            work = TRANSPOSE(smat)
            ! Workspace query
            ALLOCATE (iwork(8*np), S(np), U(np, np), VT(np, np), work_dgesdd(1))
            lwork = -1
            CALL DGESDD('S', np, np, work, np, S, U, np, vt, np, work_dgesdd, lwork, iwork, info)
            lwork = INT(work_dgesdd(1))
            DEALLOCATE (work_dgesdd); ALLOCATE (work_dgesdd(lwork))
            CALL DGESDD('S', np, np, work, np, S, U, np, vt, np, work_dgesdd, lwork, iwork, info)
            ! Construct the inverse
            DO k = 1, np
               ! invert SV
               IF (S(k) < eps_svd) THEN
                  S(k) = 0.0_dp
               ELSE
                  S(k) = 1.0_dp/S(k)
               END IF
               VT(k, :) = VT(k, :)*S(k)
            END DO
            CALL DGEMM('T', 'T', np, np, np, 1.0_dp, VT, np, U, np, 0.0_dp, gcc, np)
            DEALLOCATE (iwork, S, U, VT, work_dgesdd)
         END IF

         ! Set the coefficient of the isolated projectors to 0
         DO ip = 1, np
            IF (isoprj(ip)) THEN
               gcc(ip, ip) = 0.0_dp
            END IF
         END DO

         ! Transfer data from local to global variables

         paw_proj%zetprj(1:np, lshell) = zetp(1:np)
         paw_proj%isoprj(1:np, lshell) = isoprj(1:np)

         npgfg = 0
         notprj = 0
         DO iset = 1, nset ! iset
            IF (lshell >= lmin(iset) .AND. lshell <= lmax(iset)) THEN
               DO ip = 1, npgf(iset)
                  IF (set_radius2(ip, lshell, iset) < max_rad_local) THEN
                     npgfg = npgfg + 1
                     paw_proj%gccprj(1:np, ip, lshell, iset) = gcc(1:np, npgfg)
                  ELSE
                     notprj = notprj + 1
                     paw_proj%gccprj(1:np, ip, lshell, iset) = 0.0_dp
                  END IF
               END DO
            END IF
         END DO ! iset

         ! Print exponents and coefficients of the projectors
         IF (output_unit > 0) THEN
            WRITE (UNIT=output_unit, FMT="(/,/,T2,A,I2)") &
               "Built projector for angular momentum quantum number l= ", lshell
            WRITE (UNIT=output_unit, FMT="(T2,A,I2)") &
               "Number of isolated projectors = ", nisop
            DO iset = 1, nset ! iset
               IF (lshell >= lmin(iset) .AND. lshell <= lmax(iset)) THEN
                  WRITE (UNIT=output_unit, FMT="(/,T2,A,I5,/,/,T4,A9,(T13,4f15.6))") &
                     "Set ", iset, "exp prj: ", &
                     (paw_proj%zetprj(ip, lshell), ip=1, np)
                  DO jp = 1, npgf(iset)
                     WRITE (UNIT=output_unit, FMT="(/,T4,A9,F15.6,/,T4,A9,(t13,4E15.6))") &
                        "exp gto: ", orb_basis%zet(jp, iset), &
                        "coeff.:  ", (paw_proj%gccprj(ip, jp, &
                                                      lshell, iset), ip=1, np)
                  END DO
               END IF
            END DO ! iset
         END IF

         ! Release the working storage for the current value lshell
         DEALLOCATE (isoprj)
         DEALLOCATE (gcc, zet, zetp, smat, work)

      END DO ! lshell
      CALL cp_print_key_finished_output(output_unit, logger, force_env_section, &
                                        "DFT%PRINT%GAPW%PROJECTORS")

      ! Release the working storage for the current value lshell
      DEALLOCATE (set_radius)
      DEALLOCATE (set_radius2)

      ! Count primitives basis functions for the projectors
      paw_proj%ncgauprj = 0
      paw_proj%nsgauprj = 0
      DO lshell = 0, maxl
         paw_proj%ncgauprj = paw_proj%ncgauprj + nco(lshell)*paw_proj%nprj(lshell)
         paw_proj%nsgauprj = paw_proj%nsgauprj + nso(lshell)*paw_proj%nprj(lshell)
      END DO

      ncgauprj = paw_proj%ncgauprj
      nsgauprj = paw_proj%nsgauprj
      CALL reallocate(paw_proj%cprj, 1, ncgauprj, 1, maxso*nset)
      CALL reallocate(paw_proj%lx, 1, ncgauprj)
      CALL reallocate(paw_proj%ly, 1, ncgauprj)
      CALL reallocate(paw_proj%lz, 1, ncgauprj)
      CALL reallocate(paw_proj%first_prj, 0, maxl)
      CALL reallocate(paw_proj%last_prj, 0, maxl)
      CALL reallocate(paw_proj%cprj_s, 1, nsgauprj, 1, maxso*nset)
      CALL reallocate(paw_proj%ll, 1, nsgauprj)
      CALL reallocate(paw_proj%m, 1, nsgauprj)
      CALL reallocate(paw_proj%first_prjs, 0, maxl)

      ncgauprj = 0
      nsgauprj = 0
      DO lshell = 0, maxl
         np = paw_proj%nprj(lshell)
         paw_proj%first_prj(lshell) = ncgauprj + 1
         paw_proj%first_prjs(lshell) = nsgauprj + 1
         paw_proj%last_prj(lshell) = ncgauprj + nco(lshell)*np
         DO ip = 1, np
            DO ico = ncoset(lshell - 1) + 1, ncoset(lshell)
               ncgauprj = ncgauprj + 1
               paw_proj%lx(ncgauprj) = indco(1, ico)
               paw_proj%ly(ncgauprj) = indco(2, ico)
               paw_proj%lz(ncgauprj) = indco(3, ico)
            END DO ! ico
            DO iso = nsoset(lshell - 1) + 1, nsoset(lshell)
               nsgauprj = nsgauprj + 1
               paw_proj%ll(nsgauprj) = indso(1, iso)
               paw_proj%m(nsgauprj) = indso(2, iso)
            END DO
         END DO ! ip
      END DO ! lshell

      ms = 0
      DO iset = 1, orb_basis%nset
         ns = nsoset(lmax(iset))
         DO lshell = lmin(iset), lmax(iset)
            iprjfirst = paw_proj%first_prjs(lshell)
            np = paw_proj%nprj(lshell)
            DO ipgf = 1, npgf(iset)
               DO ip = 1, np
                  DO il = 1, nso(lshell)
                     iprjs = iprjfirst - 1 + il + (ip - 1)*nso(lshell)
                     iso = nsoset(lshell - 1) + 1 + (lshell + paw_proj%m(iprjs))

                     iso = iso + (ipgf - 1)*ns + ms
                     paw_proj%cprj_s(iprjs, iso) = &
                        paw_proj%gccprj(ip, ipgf, lshell, iset)
                  END DO ! iprjs
               END DO ! ip
            END DO ! ipgf
         END DO ! lshell
         ms = ms + maxso
      END DO ! iset

      ms = 0
      DO iset = 1, orb_basis%nset
         ns = nsoset(lmax(iset))
         DO ipgf = 1, npgf(iset)
            DO iso = nsoset(lmin(iset) - 1) + 1 + ns*(ipgf - 1) + ms, ns*ipgf + ms
               DO lshell = 0, maxl
                  np = paw_proj%nprj(lshell)
                  DO ip = 1, np
                     jp = paw_proj%first_prj(lshell) + (ip - 1)*nco(lshell) - 1
                     kp = paw_proj%first_prjs(lshell) + (ip - 1)*nso(lshell) - 1
                     DO il = 1, nco(lshell)
                        lx = indco(1, il + ncoset(lshell - 1))
                        ly = indco(2, il + ncoset(lshell - 1))
                        lz = indco(3, il + ncoset(lshell - 1))
                        iprj = jp + il
                        DO ic = 1, nso(lshell)
                           iprjs = kp + ic
                           !MK The normalization used here with s2c looks odd and might be a bug
                           !MK which has not become obvious, because it seems that paw_proj%cprj
                           !MK is not used thereafter
                           paw_proj%cprj(iprj, iso) = paw_proj%cprj(iprj, iso) + &
                                                      orbtramat(lshell)%s2c(ic, il)*paw_proj%cprj_s(iprjs, iso)* &
                                                      SQRT(dfac(2*lshell + 1)/(4.0_dp*pi)/ &
                                                           dfac(2*lx - 1)*dfac(2*ly - 1)*dfac(2*lz - 1))
                        END DO ! ic
                     END DO ! il
                  END DO ! ip
               END DO ! lshell
            END DO ! iso
         END DO ! ipgf
         ms = ms + maxso
      END DO ! iset

      ! Local coefficients for the one center expansions : oce
      ! the coefficients are calculated for the full and soft expansions
      ALLOCATE (paw_proj%local_oce_cphi_h(maxco, ncgf))
      paw_proj%local_oce_cphi_h = 0.0_dp
      ALLOCATE (paw_proj%local_oce_sphi_h(maxco, nsgf))
      paw_proj%local_oce_sphi_h = 0.0_dp
      ALLOCATE (paw_proj%sphi_h(maxco, nsgf))
      paw_proj%sphi_h = 0.0_dp

      ALLOCATE (paw_proj%local_oce_cphi_s(maxco, ncgf))
      paw_proj%local_oce_cphi_s = 0.0_dp
      ALLOCATE (paw_proj%local_oce_sphi_s(maxco, nsgf))
      paw_proj%local_oce_sphi_s = 0.0_dp
      ALLOCATE (paw_proj%sphi_s(maxco, nsgf))
      paw_proj%sphi_s = 0.0_dp

      ! Cartesian
      DO iset = 1, nset
         n = ncoset(lmax(iset))
         DO ipgf = 1, npgf(iset)
            DO ishell = 1, nshell(iset)
               lshell = l(ishell, iset)
               icomin = ncoset(lshell - 1) + 1 + n*(ipgf - 1)
               icomax = ncoset(lshell) + n*(ipgf - 1)
               icgfmin = first_cgf(ishell, iset)
               icgfmax = last_cgf(ishell, iset)
               radius = exp_radius(lshell, orb_basis%zet(ipgf, iset), &
                                   eps_fit, 1.0_dp)
               DO icgf = icgfmin, icgfmax
                  paw_proj%local_oce_cphi_h(icomin:icomax, icgf) = &
                     cphi(icomin:icomax, icgf)
                  IF (radius < rc) THEN
                     paw_proj%local_oce_cphi_s(icomin:icomax, icgf) = 0.0_dp
                  ELSE
                     paw_proj%local_oce_cphi_s(icomin:icomax, icgf) = &
                        cphi(icomin:icomax, icgf)
                  END IF
               END DO
            END DO ! ishell
         END DO ! ipgf
      END DO ! iset

      DO iset = 1, nset
         n = ncoset(lmax(iset))
         DO ipgf = 1, npgf(iset)
            DO ishell = 1, nshell(iset)
               lshell = l(ishell, iset)
               icomin = ncoset(lshell - 1) + 1 + n*(ipgf - 1)
               icomax = ncoset(lshell) + n*(ipgf - 1)
               isgfmin = first_sgf(ishell, iset)
               isgfmax = last_sgf(ishell, iset)
               radius = exp_radius(lshell, orb_basis%zet(ipgf, iset), &
                                   eps_fit, 1.0_dp)
               DO isgf = isgfmin, isgfmax
                  paw_proj%sphi_h(icomin:icomax, isgf) = &
                     sphi(icomin:icomax, isgf)
                  IF (radius < rc) THEN
                     paw_proj%sphi_s(icomin:icomax, isgf) = 0.0_dp
                  ELSE
                     paw_proj%sphi_s(icomin:icomax, isgf) = &
                        sphi(icomin:icomax, isgf)
                  END IF
               END DO
            END DO ! ishell
         END DO ! ipgf
      END DO ! iset

      DO iset = 1, nset
         n = ncoset(lmax(iset))
         ns = nsoset(lmax(iset))
         DO ipgf = 1, npgf(iset)
            DO ishell = 1, nshell(iset)
               lshell = l(ishell, iset)
               icomin = ncoset(lshell - 1) + 1 + n*(ipgf - 1)
               icomax = ncoset(lshell) + n*(ipgf - 1)
               isgfmin = first_sgf(ishell, iset)
               isgfmax = last_sgf(ishell, iset)
               isomin = nsoset(lshell - 1) + 1 + ns*(ipgf - 1)
               DO is = 1, nso(lshell)
                  iso = isomin + is - 1
                  DO ic = 1, nco(lshell)
                     ico = icomin + ic - 1
                     lx = indco(1, ic + ncoset(lshell - 1))
                     ly = indco(2, ic + ncoset(lshell - 1))
                     lz = indco(3, ic + ncoset(lshell - 1))
                     DO isgf = isgfmin, isgfmax
                        paw_proj%local_oce_sphi_h(iso, isgf) = &
                           paw_proj%local_oce_sphi_h(iso, isgf) + &
                           orbtramat(lshell)%slm_inv(is, ic)*paw_proj%sphi_h(ico, isgf)
                        paw_proj%local_oce_sphi_s(iso, isgf) = &
                           paw_proj%local_oce_sphi_s(iso, isgf) + &
                           orbtramat(lshell)%slm_inv(is, ic)*paw_proj%sphi_s(ico, isgf)
                     END DO ! isgf
                  END DO ! ic
               END DO ! is
            END DO ! ishell
         END DO ! ipgf
      END DO ! iset

      ! Index transformation OLD-NEW
      ALLOCATE (paw_proj%o2nindex(maxso*nset))
      ALLOCATE (paw_proj%n2oindex(maxso*nset))
      paw_proj%o2nindex = 0
      paw_proj%n2oindex = 0
      ico = 1
      DO iset = 1, nset
         iso_set = (iset - 1)*maxso + 1
         nsox = nsoset(lmax(iset))
         DO ipgf = 1, npgf(iset)
            iso_pgf = iso_set + (ipgf - 1)*nsox
            iso = iso_pgf + nsoset(lmin(iset) - 1)
            DO lx = lmin(iset), lmax(iset)
               DO k = 1, nso(lx)
                  paw_proj%n2oindex(ico) = iso
                  paw_proj%o2nindex(iso) = ico
                  iso = iso + 1
                  ico = ico + 1
               END DO
            END DO
         END DO
      END DO
      mp = ico - 1
      paw_proj%nsatbas = mp
      paw_proj%nsotot = nset*maxso
      ALLOCATE (paw_proj%csprj(nsgauprj, mp))
      paw_proj%csprj = 0.0_dp
      DO k = 1, mp
         ico = paw_proj%n2oindex(k)
         paw_proj%csprj(:, k) = paw_proj%cprj_s(:, ico)
      END DO

   END SUBROUTINE build_projector

! **************************************************************************************************
!> \brief   Get informations about a paw projectors set.
!> \param paw_proj_set ...
!> \param cprj ...
!> \param cprj_s ...
!> \param csprj ...
!> \param first_prj ...
!> \param first_prjs ...
!> \param last_prj ...
!> \param local_oce_sphi_h ...
!> \param local_oce_sphi_s ...
!> \param maxl ...
!> \param ncgauprj ...
!> \param nsgauprj ...
!> \param nsatbas ...
!> \param nsotot ...
!> \param nprj ...
!> \param o2nindex ...
!> \param n2oindex ...
!> \param rcprj ...
!> \param rzetprj ...
!> \param zisomin ...
!> \param zetprj ...
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE get_paw_proj_set(paw_proj_set, cprj, cprj_s, csprj, &
                               first_prj, first_prjs, last_prj, &
                               local_oce_sphi_h, local_oce_sphi_s, &
                               maxl, ncgauprj, nsgauprj, nsatbas, nsotot, nprj, &
                               o2nindex, n2oindex, &
                               rcprj, rzetprj, zisomin, zetprj)

      TYPE(paw_proj_set_type), POINTER                   :: paw_proj_set
      REAL(KIND=dp), DIMENSION(:, :), OPTIONAL, POINTER  :: cprj, cprj_s, csprj
      INTEGER, DIMENSION(:), OPTIONAL, POINTER           :: first_prj, first_prjs, last_prj
      REAL(KIND=dp), DIMENSION(:, :), OPTIONAL, POINTER  :: local_oce_sphi_h, local_oce_sphi_s
      INTEGER, INTENT(OUT), OPTIONAL                     :: maxl, ncgauprj, nsgauprj, nsatbas, nsotot
      INTEGER, DIMENSION(:), OPTIONAL, POINTER           :: nprj, o2nindex, n2oindex
      REAL(KIND=dp), INTENT(OUT), OPTIONAL               :: rcprj
      REAL(KIND=dp), DIMENSION(:, :), OPTIONAL, POINTER  :: rzetprj
      REAL(KIND=dp), DIMENSION(:), OPTIONAL, POINTER     :: zisomin
      REAL(KIND=dp), DIMENSION(:, :), OPTIONAL, POINTER  :: zetprj

      IF (ASSOCIATED(paw_proj_set)) THEN
         IF (PRESENT(cprj)) cprj => paw_proj_set%cprj
         IF (PRESENT(cprj_s)) cprj_s => paw_proj_set%cprj_s
         IF (PRESENT(csprj)) csprj => paw_proj_set%csprj
         IF (PRESENT(local_oce_sphi_h)) local_oce_sphi_h => paw_proj_set%local_oce_sphi_h
         IF (PRESENT(local_oce_sphi_s)) local_oce_sphi_s => paw_proj_set%local_oce_sphi_s
         IF (PRESENT(first_prj)) first_prj => paw_proj_set%first_prj
         IF (PRESENT(last_prj)) last_prj => paw_proj_set%last_prj
         IF (PRESENT(first_prjs)) first_prjs => paw_proj_set%first_prjs
         IF (PRESENT(maxl)) maxl = paw_proj_set%maxl
         IF (PRESENT(ncgauprj)) ncgauprj = paw_proj_set%ncgauprj
         IF (PRESENT(nsgauprj)) nsgauprj = paw_proj_set%nsgauprj
         IF (PRESENT(nsatbas)) nsatbas = paw_proj_set%nsatbas
         IF (PRESENT(nsotot)) nsotot = paw_proj_set%nsotot
         IF (PRESENT(nprj)) nprj => paw_proj_set%nprj
         IF (PRESENT(rcprj)) rcprj = paw_proj_set%rcprj
         IF (PRESENT(rzetprj)) rzetprj => paw_proj_set%rzetprj
         IF (PRESENT(zisomin)) zisomin => paw_proj_set%zisomin
         IF (PRESENT(zetprj)) zetprj => paw_proj_set%zetprj
         IF (PRESENT(o2nindex)) o2nindex => paw_proj_set%o2nindex
         IF (PRESENT(n2oindex)) n2oindex => paw_proj_set%n2oindex
      ELSE
         CPABORT("The pointer  paw_proj_set is not associated")
      END IF

   END SUBROUTINE get_paw_proj_set

! **************************************************************************************************
!> \brief   Set informations about a paw projectors set.
!> \param paw_proj_set ...
!> \param rzetprj ...
!> \param rcprj ...
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE set_paw_proj_set(paw_proj_set, rzetprj, rcprj)

      TYPE(paw_proj_set_type), POINTER                   :: paw_proj_set
      REAL(KIND=dp), DIMENSION(:, :), OPTIONAL, POINTER  :: rzetprj
      REAL(KIND=dp), INTENT(IN), OPTIONAL                :: rcprj

      IF (ASSOCIATED(paw_proj_set)) THEN
         IF (PRESENT(rzetprj)) paw_proj_set%rzetprj(:, 0:) = rzetprj(:, 0:)
         IF (PRESENT(rcprj)) paw_proj_set%rcprj = rcprj
      ELSE
         CPABORT("The pointer paw_proj_set is not associated")
      END IF

   END SUBROUTINE set_paw_proj_set

END MODULE paw_proj_set_types
