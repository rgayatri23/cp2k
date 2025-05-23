!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
MODULE qs_rho0_methods

   USE ao_util,                         ONLY: exp_radius,&
                                              gaussint_sph,&
                                              trace_r_AxB
   USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                              get_atomic_kind,&
                                              get_atomic_kind_set
   USE basis_set_types,                 ONLY: get_gto_basis_set,&
                                              gto_basis_set_type
   USE cp_control_types,                ONLY: gapw_control_type
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE mathconstants,                   ONLY: fourpi
   USE memory_utilities,                ONLY: reallocate
   USE orbital_pointers,                ONLY: indco,&
                                              indso,&
                                              nco,&
                                              ncoset,&
                                              nso,&
                                              nsoset
   USE orbital_transformation_matrices, ONLY: orbtramat
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_grid_atom,                    ONLY: grid_atom_type
   USE qs_harmonics_atom,               ONLY: get_none0_cg_list,&
                                              harmonics_atom_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              qs_kind_type,&
                                              set_qs_kind
   USE qs_local_rho_types,              ONLY: allocate_rhoz,&
                                              calculate_rhoz,&
                                              local_rho_type,&
                                              rhoz_type,&
                                              set_local_rho
   USE qs_oce_methods,                  ONLY: prj_scatter
   USE qs_rho0_types,                   ONLY: &
        allocate_multipoles, allocate_rho0_atom, allocate_rho0_atom_rad, allocate_rho0_mpole, &
        calculate_g0, get_rho0_mpole, initialize_mpole_rho, mpole_gau_overlap, mpole_rho_atom, &
        rho0_atom_type, rho0_mpole_type, write_rho0_info
   USE qs_rho_atom_types,               ONLY: get_rho_atom,&
                                              rho_atom_coeff,&
                                              rho_atom_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   ! Global parameters (only in this module)

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_rho0_methods'

   ! Public subroutines

   PUBLIC :: calculate_rho0_atom, init_rho0

CONTAINS

! **************************************************************************************************
!> \brief ...
!> \param mp_gau ...
!> \param orb_basis ...
!> \param harmonics ...
!> \param nchannels ...
!> \param nsotot ...
! **************************************************************************************************
   SUBROUTINE calculate_mpole_gau(mp_gau, orb_basis, harmonics, nchannels, nsotot)

      TYPE(mpole_gau_overlap)                            :: mp_gau
      TYPE(gto_basis_set_type), POINTER                  :: orb_basis
      TYPE(harmonics_atom_type), POINTER                 :: harmonics
      INTEGER, INTENT(IN)                                :: nchannels, nsotot

      CHARACTER(len=*), PARAMETER :: routineN = 'calculate_mpole_gau'

      INTEGER :: handle, icg, ig1, ig2, ipgf1, ipgf2, iset1, iset2, iso, iso1, iso2, l, l1, l2, &
         llmax, m1, m2, max_iso_not0_local, max_s_harm, maxl, maxso, n1, n2, nset
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: cg_n_list
      INTEGER, ALLOCATABLE, DIMENSION(:, :, :)           :: cg_list
      INTEGER, DIMENSION(:), POINTER                     :: lmax, lmin, npgf
      REAL(KIND=dp)                                      :: zet1, zet2
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: zet
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER         :: my_CG

      CALL timeset(routineN, handle)

      NULLIFY (lmax, lmin, npgf, my_CG, zet)

      CALL reallocate(mp_gau%Qlm_gg, 1, nsotot, 1, nsotot, 1, nchannels)

      CALL get_gto_basis_set(gto_basis_set=orb_basis, &
                             lmax=lmax, lmin=lmin, maxso=maxso, &
                             npgf=npgf, nset=nset, zet=zet, maxl=maxl)

      max_s_harm = harmonics%max_s_harm
      llmax = harmonics%llmax

      ALLOCATE (cg_list(2, nsoset(maxl)**2, max_s_harm), cg_n_list(max_s_harm))

      my_CG => harmonics%my_CG

      m1 = 0
      DO iset1 = 1, nset
         m2 = 0
         DO iset2 = 1, nset

            CALL get_none0_cg_list(my_CG, lmin(iset1), lmax(iset1), lmin(iset2), lmax(iset2), &
                                   max_s_harm, llmax, cg_list, cg_n_list, max_iso_not0_local)

            n1 = nsoset(lmax(iset1))
            DO ipgf1 = 1, npgf(iset1)
               zet1 = zet(ipgf1, iset1)

               n2 = nsoset(lmax(iset2))
               DO ipgf2 = 1, npgf(iset2)
                  zet2 = zet(ipgf2, iset2)

                  DO iso = 1, MIN(nchannels, max_iso_not0_local)
                     l = indso(1, iso)
                     DO icg = 1, cg_n_list(iso)
                        iso1 = cg_list(1, icg, iso)
                        iso2 = cg_list(2, icg, iso)

                        l1 = indso(1, iso1)
                        l2 = indso(1, iso2)
                        ig1 = iso1 + n1*(ipgf1 - 1) + m1
                        ig2 = iso2 + n2*(ipgf2 - 1) + m2

                        mp_gau%Qlm_gg(ig1, ig2, iso) = fourpi/(2._dp*l + 1._dp)* &
                                                       my_CG(iso1, iso2, iso)*gaussint_sph(zet1 + zet2, l + l1 + l2)
                     END DO ! icg
                  END DO ! iso

               END DO ! ipgf2
            END DO ! ipgf1
            m2 = m2 + maxso
         END DO ! iset2
         m1 = m1 + maxso
      END DO ! iset1

      DEALLOCATE (cg_list, cg_n_list)

      CALL timestop(handle)
   END SUBROUTINE calculate_mpole_gau

! **************************************************************************************************
!> \brief ...
!> \param gapw_control ...
!> \param rho_atom_set ...
!> \param rho0_atom_set ...
!> \param rho0_mp ...
!> \param a_list ...
!> \param natom ...
!> \param ikind ...
!> \param qs_kind ...
!> \param rho0_h_tot ...
! **************************************************************************************************
   SUBROUTINE calculate_rho0_atom(gapw_control, rho_atom_set, rho0_atom_set, &
                                  rho0_mp, a_list, natom, ikind, qs_kind, rho0_h_tot)

      TYPE(gapw_control_type), POINTER                   :: gapw_control
      TYPE(rho_atom_type), DIMENSION(:), POINTER         :: rho_atom_set
      TYPE(rho0_atom_type), DIMENSION(:), POINTER        :: rho0_atom_set
      TYPE(rho0_mpole_type), POINTER                     :: rho0_mp
      INTEGER, DIMENSION(:), INTENT(IN)                  :: a_list
      INTEGER, INTENT(IN)                                :: natom, ikind
      TYPE(qs_kind_type), INTENT(IN)                     :: qs_kind
      REAL(KIND=dp), INTENT(INOUT)                       :: rho0_h_tot

      CHARACTER(len=*), PARAMETER :: routineN = 'calculate_rho0_atom'

      INTEGER                                            :: handle, iat, iatom, ic, ico, ir, is, &
                                                            iso, ispin, l, lmax0, lshell, lx, ly, &
                                                            lz, nr, nsotot, nspins
      LOGICAL                                            :: paw_atom
      REAL(KIND=dp)                                      :: sum1
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :, :)     :: cpc_ah, cpc_as
      REAL(KIND=dp), DIMENSION(:), POINTER               :: norm_g0l_h
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: g0_h, vg0_h
      TYPE(grid_atom_type), POINTER                      :: g_atom
      TYPE(harmonics_atom_type), POINTER                 :: harmonics
      TYPE(mpole_gau_overlap), POINTER                   :: mpole_gau
      TYPE(mpole_rho_atom), POINTER                      :: mpole_rho
      TYPE(rho_atom_coeff), DIMENSION(:), POINTER        :: cpc_h, cpc_s
      TYPE(rho_atom_type), POINTER                       :: rho_atom

      CALL timeset(routineN, handle)

      NULLIFY (mpole_gau)
      NULLIFY (mpole_rho)
      NULLIFY (g0_h, vg0_h, g_atom)
      NULLIFY (norm_g0l_h, harmonics)

      CALL get_rho0_mpole(rho0_mpole=rho0_mp, ikind=ikind, &
                          l0_ikind=lmax0, mp_gau_ikind=mpole_gau, &
                          g0_h=g0_h, &
                          vg0_h=vg0_h, &
                          norm_g0l_h=norm_g0l_h)

      CALL get_qs_kind(qs_kind, harmonics=harmonics, paw_atom=paw_atom, grid_atom=g_atom)

      nr = g_atom%nr

      ! Set density coefficient to zero before the calculation
      DO iat = 1, natom
         iatom = a_list(iat)
         rho0_atom_set(iatom)%rho0_rad_h%r_coef = 0.0_dp
         rho0_mp%mp_rho(iatom)%Qlm_tot = 0.0_dp
         rho0_mp%mp_rho(iatom)%Qlm_tot(1) = rho0_mp%mp_rho(iatom)%Qlm_z
         rho0_mp%mp_rho(iatom)%Q0 = 0.0_dp
         rho0_mp%mp_rho(iatom)%Qlm_car = 0.0_dp
      END DO

      IF (.NOT. (.NOT. paw_atom .AND. gapw_control%nopaw_as_gpw)) THEN
         DO iat = 1, natom
            iatom = a_list(iat)
            mpole_rho => rho0_mp%mp_rho(iatom)
            rho_atom => rho_atom_set(iatom)

            IF (paw_atom) THEN
               NULLIFY (cpc_h, cpc_s)
               CALL get_rho_atom(rho_atom=rho_atom, cpc_h=cpc_h, cpc_s=cpc_s)
               nspins = SIZE(cpc_h)
               nsotot = SIZE(mpole_gau%Qlm_gg, 1)
               ALLOCATE (cpc_ah(nsotot, nsotot, nspins))
               cpc_ah = 0._dp
               ALLOCATE (cpc_as(nsotot, nsotot, nspins))
               cpc_as = 0._dp
               DO ispin = 1, nspins
                  CALL prj_scatter(cpc_h(ispin)%r_coef, cpc_ah(:, :, ispin), qs_kind)
                  CALL prj_scatter(cpc_s(ispin)%r_coef, cpc_as(:, :, ispin), qs_kind)
               END DO
            END IF

            ! Total charge (hard-soft) at atom
            IF (paw_atom) THEN
               DO ispin = 1, nspins
                  mpole_rho%Q0(ispin) = (trace_r_AxB(mpole_gau%Qlm_gg(:, :, 1), nsotot, &
                                                     cpc_ah(:, :, ispin), nsotot, nsotot, nsotot) &
                                         - trace_r_AxB(mpole_gau%Qlm_gg(:, :, 1), nsotot, &
                                                       cpc_as(:, :, ispin), nsotot, nsotot, nsotot))/SQRT(fourpi)
               END DO
            END IF
            ! Multipoles of local charge distribution
            DO iso = 1, nsoset(lmax0)
               l = indso(1, iso)
               IF (paw_atom) THEN
                  mpole_rho%Qlm_h(iso) = 0.0_dp
                  mpole_rho%Qlm_s(iso) = 0.0_dp

                  DO ispin = 1, nspins
                     mpole_rho%Qlm_h(iso) = mpole_rho%Qlm_h(iso) + &
                                            trace_r_AxB(mpole_gau%Qlm_gg(:, :, iso), nsotot, &
                                                        cpc_ah(:, :, ispin), nsotot, nsotot, nsotot)
                     mpole_rho%Qlm_s(iso) = mpole_rho%Qlm_s(iso) + &
                                            trace_r_AxB(mpole_gau%Qlm_gg(:, :, iso), nsotot, &
                                                        cpc_as(:, :, ispin), nsotot, nsotot, nsotot)
                  END DO ! ispin

                  mpole_rho%Qlm_tot(iso) = mpole_rho%Qlm_tot(iso) + &
                                           mpole_rho%Qlm_h(iso) - mpole_rho%Qlm_s(iso)
               END IF

               rho0_atom_set(iatom)%rho0_rad_h%r_coef(1:nr, iso) = &
                  g0_h(1:nr, l)*mpole_rho%Qlm_tot(iso)
               rho0_atom_set(iatom)%vrho0_rad_h%r_coef(1:nr, iso) = &
                  vg0_h(1:nr, l)*mpole_rho%Qlm_tot(iso)

               sum1 = 0.0_dp
               DO ir = 1, nr
                  sum1 = sum1 + g_atom%wr(ir)* &
                         rho0_atom_set(iatom)%rho0_rad_h%r_coef(ir, iso)
               END DO
               rho0_h_tot = rho0_h_tot + sum1*harmonics%slm_int(iso)
            END DO ! iso
            IF (paw_atom) THEN
               DEALLOCATE (cpc_ah, cpc_as)
            END IF
         END DO ! iat
      END IF

      ! Transform the coefficinets from spherical to Cartesian
      IF (.NOT. paw_atom .AND. gapw_control%nopaw_as_gpw) THEN
         DO iat = 1, natom
            iatom = a_list(iat)
            mpole_rho => rho0_mp%mp_rho(iatom)

            DO lshell = 0, lmax0
               DO ic = 1, nco(lshell)
                  ico = ic + ncoset(lshell - 1)
                  mpole_rho%Qlm_car(ico) = 0.0_dp
               END DO
            END DO
         END DO
      ELSE
         DO iat = 1, natom
            iatom = a_list(iat)
            mpole_rho => rho0_mp%mp_rho(iatom)
            DO lshell = 0, lmax0
               DO ic = 1, nco(lshell)
                  ico = ic + ncoset(lshell - 1)
                  mpole_rho%Qlm_car(ico) = 0.0_dp
                  lx = indco(1, ico)
                  ly = indco(2, ico)
                  lz = indco(3, ico)
                  DO is = 1, nso(lshell)
                     iso = is + nsoset(lshell - 1)
                     mpole_rho%Qlm_car(ico) = mpole_rho%Qlm_car(ico) + &
                                              norm_g0l_h(lshell)* &
                                              orbtramat(lshell)%slm(is, ic)* &
                                              mpole_rho%Qlm_tot(iso)

                  END DO
               END DO
            END DO ! lshell
         END DO ! iat
      END IF
      !MI Get rid of full gapw

      CALL timestop(handle)

   END SUBROUTINE calculate_rho0_atom

! **************************************************************************************************
!> \brief ...
!> \param local_rho_set ...
!> \param qs_env ...
!> \param gapw_control ...
!> \param tddft ...
! **************************************************************************************************
   SUBROUTINE init_rho0(local_rho_set, qs_env, gapw_control, tddft)

      TYPE(local_rho_type), POINTER                      :: local_rho_set
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(gapw_control_type), POINTER                   :: gapw_control
      LOGICAL, INTENT(in)                                :: tddft

      CHARACTER(len=*), PARAMETER                        :: routineN = 'init_rho0'

      CHARACTER(LEN=default_string_length)               :: unit_str
      INTEGER :: handle, iat, iatom, ikind, l, l_rho1_max, laddg, lmaxg, maxl, maxnset, maxso, &
         nat, natom, nchan_c, nchan_s, nkind, nr, nset, nsotot, output_unit
      INTEGER, DIMENSION(:), POINTER                     :: atom_list
      LOGICAL                                            :: paw_atom
      REAL(KIND=dp)                                      :: alpha_core, eps_Vrho0, max_rpgf0_s, &
                                                            radius, rc_min, rc_orb, &
                                                            total_rho_core_rspace, zeff
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(grid_atom_type), POINTER                      :: grid_atom
      TYPE(gto_basis_set_type), POINTER                  :: orb_basis
      TYPE(harmonics_atom_type), POINTER                 :: harmonics
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(rho0_atom_type), DIMENSION(:), POINTER        :: rho0_atom_set
      TYPE(rho0_mpole_type), POINTER                     :: rho0_mpole
      TYPE(rhoz_type), DIMENSION(:), POINTER             :: rhoz_set
      TYPE(section_vals_type), POINTER                   :: dft_section

      CALL timeset(routineN, handle)

      NULLIFY (logger)
      logger => cp_get_default_logger()

      NULLIFY (qs_kind_set)
      NULLIFY (atomic_kind_set)
      NULLIFY (harmonics)
      NULLIFY (orb_basis)
      NULLIFY (rho0_mpole)
      NULLIFY (rho0_atom_set)
      NULLIFY (rhoz_set)

      CALL get_qs_env(qs_env=qs_env, qs_kind_set=qs_kind_set, &
                      atomic_kind_set=atomic_kind_set)

      nkind = SIZE(atomic_kind_set)
      eps_Vrho0 = gapw_control%eps_Vrho0

      ! Initialize rhoz total to zero
      ! in gapw rhoz is calculated on local the lebedev grids
      total_rho_core_rspace = 0.0_dp

      CALL get_atomic_kind_set(atomic_kind_set, natom=natom)

      ! Initialize the multipole and the compensation charge type
      CALL allocate_rho0_mpole(rho0_mpole)
      CALL allocate_rho0_atom(rho0_atom_set, natom)

      ! Allocate the multipole set
      CALL allocate_multipoles(rho0_mpole%mp_rho, natom, rho0_mpole%mp_gau, nkind)

      ! Allocate the core density on the radial grid for each kind: rhoz_set
      CALL allocate_rhoz(rhoz_set, nkind)

      ! For each kind, determine the max l for the compensation charge density
      lmaxg = gapw_control%lmax_rho0
      laddg = gapw_control%ladd_rho0

      CALL reallocate(rho0_mpole%lmax0_kind, 1, nkind)

      rho0_mpole%lmax_0 = 0
      rc_min = 100.0_dp
      maxnset = 0
      DO ikind = 1, nkind
         CALL get_atomic_kind(atomic_kind_set(ikind), atom_list=atom_list, natom=nat)
         CALL get_qs_kind(qs_kind_set(ikind), &
                          basis_set=orb_basis, &
                          ngrid_rad=nr, &
                          grid_atom=grid_atom, &
                          harmonics=harmonics, &
                          paw_atom=paw_atom, &
                          hard0_radius=rc_orb, &
                          zeff=zeff, &
                          alpha_core_charge=alpha_core)

         ! Set charge distribution of ionic cores to zero when computing the response-density
         IF (tddft) zeff = 0.0_dp

         CALL get_gto_basis_set(gto_basis_set=orb_basis, &
                                maxl=maxl, &
                                maxso=maxso, nset=nset)

         maxnset = MAX(maxnset, nset)

         l_rho1_max = indso(1, harmonics%max_iso_not0)
         IF (paw_atom) THEN
            rho0_mpole%lmax0_kind(ikind) = MIN(2*maxl, l_rho1_max, maxl + laddg, lmaxg)
         ELSE
            rho0_mpole%lmax0_kind(ikind) = 0
         END IF

         CALL set_qs_kind(qs_kind_set(ikind), lmax_rho0=rho0_mpole%lmax0_kind(ikind))

         IF (gapw_control%lrho1_eq_lrho0) harmonics%max_iso_not0 = &
            nsoset(rho0_mpole%lmax0_kind(ikind))

         rho0_mpole%lmax_0 = MAX(rho0_mpole%lmax_0, rho0_mpole%lmax0_kind(ikind))
         rc_min = MIN(rc_min, rc_orb)

         nchan_s = nsoset(rho0_mpole%lmax0_kind(ikind))
         nchan_c = ncoset(rho0_mpole%lmax0_kind(ikind))
         nsotot = maxso*nset

         DO iat = 1, nat
            iatom = atom_list(iat)
            ! Allocate the multipole for rho1_h rho1_s and rho_z
            CALL initialize_mpole_rho(rho0_mpole%mp_rho(iatom), nchan_s, nchan_c, zeff)
            ! Allocate the radial part of rho0_h and rho0_s
            ! This is calculated on the radial grid centered at the atomic position
            CALL allocate_rho0_atom_rad(rho0_atom_set(iatom), nr, nchan_s)
         END DO

         IF (paw_atom) THEN
            ! Calculate multipoles given by the product of 2 primitives Qlm_gg
            CALL calculate_mpole_gau(rho0_mpole%mp_gau(ikind), &
                                     orb_basis, harmonics, nchan_s, nsotot)
         END IF

         ! Calculate the core density rhoz
         ! exp(-alpha_c**2 r**2)Z(alpha_c**2/pi)**(3/2)
         ! on the logarithmic radial grid
         ! WARNING: alpha_core_charge = alpha_c**2
         CALL calculate_rhoz(rhoz_set(ikind), grid_atom, alpha_core, zeff, &
                             nat, total_rho_core_rspace, harmonics)
      END DO ! ikind
      total_rho_core_rspace = -total_rho_core_rspace

      IF (gapw_control%alpha0_hard_from_input) THEN
         ! The exponent for the compensation charge rho0_hard is read from input
         rho0_mpole%zet0_h = gapw_control%alpha0_hard
      ELSE
         ! Calculate the exponent for the compensation charge rho0_hard
         rho0_mpole%zet0_h = 0.1_dp
         DO
            radius = exp_radius(rho0_mpole%lmax_0, rho0_mpole%zet0_h, eps_Vrho0, 1.0_dp)
            IF (radius <= rc_min) EXIT
            rho0_mpole%zet0_h = rho0_mpole%zet0_h + 0.1_dp
         END DO

      END IF

      ! Allocate and calculate the normalization factors for g0_lm_h and g0_lm_s
      CALL reallocate(rho0_mpole%norm_g0l_h, 0, rho0_mpole%lmax_0)
      DO l = 0, rho0_mpole%lmax_0
         rho0_mpole%norm_g0l_h(l) = (2._dp*l + 1._dp)/ &
                                    (fourpi*gaussint_sph(rho0_mpole%zet0_h, 2*l))
      END DO

      ! Allocate and Initialize the g0 gaussians used to build the compensation density
      ! and calculate the interaction radii
      max_rpgf0_s = 0.0_dp
      DO ikind = 1, nkind
         CALL get_qs_kind(qs_kind_set(ikind), grid_atom=grid_atom)
         CALL calculate_g0(rho0_mpole, grid_atom, ikind)
         CALL interaction_radii_g0(rho0_mpole, ikind, eps_Vrho0, max_rpgf0_s)
      END DO
      rho0_mpole%max_rpgf0_s = max_rpgf0_s

      CALL set_local_rho(local_rho_set, rho0_atom_set=rho0_atom_set, rho0_mpole=rho0_mpole, rhoz_set=rhoz_set)
      local_rho_set%rhoz_tot = total_rho_core_rspace

      dft_section => section_vals_get_subs_vals(qs_env%input, "DFT")
      output_unit = cp_print_key_unit_nr(logger, dft_section, "PRINT%GAPW%RHO0_INFORMATION", &
                                         extension=".Log")
      CALL section_vals_val_get(dft_section, "PRINT%GAPW%RHO0_INFORMATION%UNIT", c_val=unit_str)
      IF (output_unit > 0) THEN
         CALL write_rho0_info(rho0_mpole, unit_str, output_unit)
      END IF
      CALL cp_print_key_finished_output(output_unit, logger, dft_section, &
                                        "PRINT%GAPW%RHO0_INFORMATION")

      CALL timestop(handle)

   END SUBROUTINE init_rho0

! **************************************************************************************************
!> \brief ...
!> \param rho0_mpole ...
!> \param ik ...
!> \param eps_Vrho0 ...
!> \param max_rpgf0_s ...
! **************************************************************************************************
   SUBROUTINE interaction_radii_g0(rho0_mpole, ik, eps_Vrho0, max_rpgf0_s)

      TYPE(rho0_mpole_type), POINTER                     :: rho0_mpole
      INTEGER, INTENT(IN)                                :: ik
      REAL(KIND=dp), INTENT(IN)                          :: eps_Vrho0
      REAL(KIND=dp), INTENT(INOUT)                       :: max_rpgf0_s

      INTEGER                                            :: l, lmax
      REAL(KIND=dp)                                      :: r_h, z0_h
      REAL(KIND=dp), DIMENSION(:), POINTER               :: ng0_h

      CALL get_rho0_mpole(rho0_mpole, ikind=ik, l0_ikind=lmax, &
                          zet0_h=z0_h, norm_g0l_h=ng0_h)
      r_h = 0.0_dp
      DO l = 0, lmax
         r_h = MAX(r_h, exp_radius(l, z0_h, eps_Vrho0, ng0_h(l), rlow=r_h))
      END DO

      rho0_mpole%mp_gau(ik)%rpgf0_h = r_h
      rho0_mpole%mp_gau(ik)%rpgf0_s = r_h
      max_rpgf0_s = MAX(max_rpgf0_s, r_h)

   END SUBROUTINE interaction_radii_g0

END MODULE qs_rho0_methods
