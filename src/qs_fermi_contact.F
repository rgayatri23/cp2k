!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Distribution of the Fermi contact integral matrix.
!> \par History
!> \author VW (27.02.2009)
! **************************************************************************************************
MODULE qs_fermi_contact

   USE ai_fermi_contact,                ONLY: fermi_contact
   USE basis_set_types,                 ONLY: gto_basis_set_p_type,&
                                              gto_basis_set_type
   USE block_p_types,                   ONLY: block_p_type
   USE cell_types,                      ONLY: cell_type,&
                                              pbc
   USE cp_dbcsr_output,                 ONLY: cp_dbcsr_write_sparse_matrix
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_p_file,&
                                              cp_print_key_finished_output,&
                                              cp_print_key_should_output,&
                                              cp_print_key_unit_nr
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_get_block_p,&
                                              dbcsr_p_type
   USE input_section_types,             ONLY: section_vals_val_get
   USE kinds,                           ONLY: dp
   USE orbital_pointers,                ONLY: init_orbital_pointers,&
                                              ncoset
   USE particle_types,                  ONLY: particle_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_kind_types,                   ONLY: get_qs_kind,&
                                              get_qs_kind_set,&
                                              qs_kind_type
   USE qs_neighbor_list_types,          ONLY: get_iterator_info,&
                                              neighbor_list_iterate,&
                                              neighbor_list_iterator_create,&
                                              neighbor_list_iterator_p_type,&
                                              neighbor_list_iterator_release,&
                                              neighbor_list_set_p_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

! *** Global parameters ***

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_fermi_contact'

! *** Public subroutines ***

   PUBLIC :: build_fermi_contact_matrix

CONTAINS

! **************************************************************************************************
!> \brief   Calculation of the Fermi contact matrix over Cartesian
!>          Gaussian functions.
!> \param qs_env ...
!> \param matrix_fc ...
!> \param rc ...
!> \date    27.02.2009
!> \author  VW
!> \version 1.0
! **************************************************************************************************

   SUBROUTINE build_fermi_contact_matrix(qs_env, matrix_fc, rc)

      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_fc
      REAL(dp), DIMENSION(3), INTENT(IN)                 :: rc

      CHARACTER(len=*), PARAMETER :: routineN = 'build_fermi_contact_matrix'

      INTEGER :: after, handle, iatom, icol, ikind, inode, irow, iset, iw, jatom, jkind, jset, &
         last_jatom, ldai, ldfc, maxco, maxlgto, maxsgf, natom, ncoa, ncob, nkind, nseta, nsetb, &
         sgfa, sgfb
      INTEGER, DIMENSION(:), POINTER                     :: la_max, la_min, lb_max, lb_min, npgfa, &
                                                            npgfb, nsgfa, nsgfb
      INTEGER, DIMENSION(:, :), POINTER                  :: first_sgfa, first_sgfb
      LOGICAL                                            :: found, new_atom_b, omit_headers
      REAL(KIND=dp)                                      :: dab, rab2
      REAL(KIND=dp), ALLOCATABLE, DIMENSION(:, :)        :: fcab, work
      REAL(KIND=dp), DIMENSION(3)                        :: ra, rab, rac, rb, rbc
      REAL(KIND=dp), DIMENSION(:), POINTER               :: set_radius_a, set_radius_b
      REAL(KIND=dp), DIMENSION(:, :), POINTER            :: rpgfa, rpgfb, sphi_a, sphi_b, zeta, zetb
      TYPE(block_p_type), ALLOCATABLE, DIMENSION(:)      :: fcint
      TYPE(cell_type), POINTER                           :: cell
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(gto_basis_set_p_type), DIMENSION(:), POINTER  :: basis_set_list
      TYPE(gto_basis_set_type), POINTER                  :: basis_set_a, basis_set_b
      TYPE(neighbor_list_iterator_p_type), &
         DIMENSION(:), POINTER                           :: nl_iterator
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(qs_kind_type), POINTER                        :: qs_kind

      CALL timeset(routineN, handle)

      NULLIFY (cell, sab_orb, qs_kind_set, particle_set, para_env)
      NULLIFY (logger)

      logger => cp_get_default_logger()

      CALL get_qs_env(qs_env=qs_env, &
                      qs_kind_set=qs_kind_set, &
                      particle_set=particle_set, &
                      para_env=para_env, &
                      sab_orb=sab_orb, &
                      cell=cell)

      nkind = SIZE(qs_kind_set)
      natom = SIZE(particle_set)

      ! *** Allocate work storage ***

      CALL get_qs_kind_set(qs_kind_set=qs_kind_set, &
                           maxco=maxco, &
                           maxlgto=maxlgto, &
                           maxsgf=maxsgf)

      ldai = ncoset(maxlgto)
      CALL init_orbital_pointers(ldai)

      ldfc = maxco
      ALLOCATE (fcab(ldfc, ldfc))
      fcab(:, :) = 0.0_dp

      ALLOCATE (work(maxco, maxsgf))
      work(:, :) = 0.0_dp

      ALLOCATE (fcint(1))
      NULLIFY (fcint(1)%block)

      ALLOCATE (basis_set_list(nkind))
      DO ikind = 1, nkind
         qs_kind => qs_kind_set(ikind)
         CALL get_qs_kind(qs_kind=qs_kind, basis_set=basis_set_a)
         IF (ASSOCIATED(basis_set_a)) THEN
            basis_set_list(ikind)%gto_basis_set => basis_set_a
         ELSE
            NULLIFY (basis_set_list(ikind)%gto_basis_set)
         END IF
      END DO
      CALL neighbor_list_iterator_create(nl_iterator, sab_orb)
      DO WHILE (neighbor_list_iterate(nl_iterator) == 0)
         CALL get_iterator_info(nl_iterator, ikind=ikind, jkind=jkind, inode=inode, &
                                iatom=iatom, jatom=jatom, r=rab)
         basis_set_a => basis_set_list(ikind)%gto_basis_set
         IF (.NOT. ASSOCIATED(basis_set_a)) CYCLE
         basis_set_b => basis_set_list(jkind)%gto_basis_set
         IF (.NOT. ASSOCIATED(basis_set_b)) CYCLE
         ra = pbc(particle_set(iatom)%r, cell)
         ! basis ikind
         first_sgfa => basis_set_a%first_sgf
         la_max => basis_set_a%lmax
         la_min => basis_set_a%lmin
         npgfa => basis_set_a%npgf
         nseta = basis_set_a%nset
         nsgfa => basis_set_a%nsgf_set
         rpgfa => basis_set_a%pgf_radius
         set_radius_a => basis_set_a%set_radius
         sphi_a => basis_set_a%sphi
         zeta => basis_set_a%zet
         ! basis jkind
         first_sgfb => basis_set_b%first_sgf
         lb_max => basis_set_b%lmax
         lb_min => basis_set_b%lmin
         npgfb => basis_set_b%npgf
         nsetb = basis_set_b%nset
         nsgfb => basis_set_b%nsgf_set
         rpgfb => basis_set_b%pgf_radius
         set_radius_b => basis_set_b%set_radius
         sphi_b => basis_set_b%sphi
         zetb => basis_set_b%zet

         IF (inode == 1) last_jatom = 0

         rb = rab + ra
         rab2 = rab(1)*rab(1) + rab(2)*rab(2) + rab(3)*rab(3)
         dab = SQRT(rab2)
         rac = pbc(ra, rc, cell)
         rbc = rac - rab

         IF (jatom /= last_jatom) THEN
            new_atom_b = .TRUE.
            last_jatom = jatom
         ELSE
            new_atom_b = .FALSE.
         END IF

         IF (new_atom_b) THEN
            IF (iatom <= jatom) THEN
               irow = iatom
               icol = jatom
            ELSE
               irow = jatom
               icol = iatom
            END IF

            NULLIFY (fcint(1)%block)
            CALL dbcsr_get_block_p(matrix=matrix_fc(1)%matrix, &
                                   row=irow, col=icol, BLOCK=fcint(1)%block, found=found)
         END IF

         DO iset = 1, nseta

            ncoa = npgfa(iset)*ncoset(la_max(iset))
            sgfa = first_sgfa(1, iset)

            DO jset = 1, nsetb

               IF (set_radius_a(iset) + set_radius_b(jset) < dab) CYCLE

               ncob = npgfb(jset)*ncoset(lb_max(jset))
               sgfb = first_sgfb(1, jset)

               ! *** Calculate the primitive fermi contact integrals ***

               CALL fermi_contact(la_max(iset), la_min(iset), npgfa(iset), &
                                  rpgfa(:, iset), zeta(:, iset), &
                                  lb_max(jset), lb_min(jset), npgfb(jset), &
                                  rpgfb(:, jset), zetb(:, jset), &
                                  rac, rbc, dab, fcab, SIZE(fcab, 1))

               ! *** Contraction step ***

               CALL dgemm("N", "N", ncoa, nsgfb(jset), ncob, &
                          1.0_dp, fcab(1, 1), SIZE(fcab, 1), &
                          sphi_b(1, sgfb), SIZE(sphi_b, 1), &
                          0.0_dp, work(1, 1), SIZE(work, 1))

               IF (iatom <= jatom) THEN

                  CALL dgemm("T", "N", nsgfa(iset), nsgfb(jset), ncoa, &
                             1.0_dp, sphi_a(1, sgfa), SIZE(sphi_a, 1), &
                             work(1, 1), SIZE(work, 1), &
                             1.0_dp, fcint(1)%block(sgfa, sgfb), &
                             SIZE(fcint(1)%block, 1))

               ELSE

                  CALL dgemm("T", "N", nsgfb(jset), nsgfa(iset), ncoa, &
                             1.0_dp, work(1, 1), SIZE(work, 1), &
                             sphi_a(1, sgfa), SIZE(sphi_a, 1), &
                             1.0_dp, fcint(1)%block(sgfb, sgfa), &
                             SIZE(fcint(1)%block, 1))

               END IF

            END DO

         END DO

      END DO
      CALL neighbor_list_iterator_release(nl_iterator)

      ! *** Release work storage ***
      DEALLOCATE (basis_set_list)

      DEALLOCATE (fcab)

      DEALLOCATE (work)

      NULLIFY (fcint(1)%block)
      DEALLOCATE (fcint)

!   *** Print the Fermi contact matrix, if requested ***

      IF (BTEST(cp_print_key_should_output(logger%iter_info, &
                                           qs_env%input, "DFT%PRINT%AO_MATRICES/FERMI_CONTACT"), cp_p_file)) THEN
         iw = cp_print_key_unit_nr(logger, qs_env%input, "DFT%PRINT%AO_MATRICES/FERMI_CONTACT", &
                                   extension=".Log")
         CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%NDIGITS", i_val=after)
         CALL section_vals_val_get(qs_env%input, "DFT%PRINT%AO_MATRICES%OMIT_HEADERS", l_val=omit_headers)
         after = MIN(MAX(after, 1), 16)
         CALL cp_dbcsr_write_sparse_matrix(matrix_fc(1)%matrix, 4, after, qs_env, &
                                           para_env, output_unit=iw, omit_headers=omit_headers)
         CALL cp_print_key_finished_output(iw, logger, qs_env%input, &
                                           "DFT%PRINT%AO_MATRICES/FERMI_CONTACT")
      END IF

      CALL timestop(handle)

   END SUBROUTINE build_fermi_contact_matrix

! **************************************************************************************************

END MODULE qs_fermi_contact

