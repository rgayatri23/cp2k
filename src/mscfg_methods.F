!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Subroutines to perform calculations on molecules from a bigger
!>        system. Useful to generate a high-quality MO guess for systems
!>        of many molecules with complex electronic structure, to bootstrap
!>        ALMO simulations, etc.
!> \par History
!>      10.2014 Rustam Z Khaliullin
!>      09.2018 ALMO smearing support and ALMO diag+molecular_guess patch [Ruben Staub]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
MODULE mscfg_methods
   USE almo_scf_types,                  ONLY: almo_scf_env_type
   USE atomic_kind_types,               ONLY: get_atomic_kind
   USE cell_types,                      ONLY: cell_type
   USE cp_dbcsr_operations,             ONLY: copy_fm_to_dbcsr
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_get_default_unit_nr,&
                                              cp_logger_type
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_subsys_methods,               ONLY: create_small_subsys
   USE cp_subsys_types,                 ONLY: cp_subsys_get,&
                                              cp_subsys_release,&
                                              cp_subsys_type
   USE dbcsr_api,                       ONLY: dbcsr_copy,&
                                              dbcsr_create,&
                                              dbcsr_type_no_symmetry
   USE force_env_types,                 ONLY: force_env_get,&
                                              force_env_type
   USE global_types,                    ONLY: global_environment_type
   USE input_constants,                 ONLY: almo_frz_crystal,&
                                              almo_frz_none,&
                                              do_qs,&
                                              molecular_guess
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type,&
                                              section_vals_val_get,&
                                              section_vals_val_set
   USE kinds,                           ONLY: default_string_length
   USE molecule_types,                  ONLY: get_molecule_set_info,&
                                              molecule_type
   USE mscfg_types,                     ONLY: molecular_scf_guess_env_init,&
                                              molecular_scf_guess_env_type,&
                                              mscfg_max_moset_size
   USE particle_list_types,             ONLY: particle_list_type
   USE qs_energy,                       ONLY: qs_energies
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment,                  ONLY: qs_init
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_env_create,&
                                              qs_env_release,&
                                              qs_environment_type
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'mscfg_methods'

   PUBLIC :: loop_over_molecules, do_mol_loop

CONTAINS

! **************************************************************************************************
!> \brief Prepare data for calculations on isolated molecules.
!> \param globenv ...
!> \param force_env ...
!> \par   History
!>        10.2014 created [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE loop_over_molecules(globenv, force_env)

      TYPE(global_environment_type), POINTER             :: globenv
      TYPE(force_env_type), POINTER                      :: force_env

      INTEGER                                            :: nmols
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: charge_of_frag, first_atom_of_frag, &
                                                            last_atom_of_frag, multip_of_frag
      TYPE(molecule_type), DIMENSION(:), POINTER         :: molecule_set
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CALL force_env_get(force_env, qs_env=qs_env)
      CPASSERT(ASSOCIATED(qs_env))
      CALL get_qs_env(qs_env, &
                      molecule_set=molecule_set)

      nmols = SIZE(molecule_set)

      ALLOCATE (first_atom_of_frag(nmols))
      ALLOCATE (last_atom_of_frag(nmols))
      ALLOCATE (charge_of_frag(nmols))
      ALLOCATE (multip_of_frag(nmols))

      CALL get_molecule_set_info(molecule_set, &
                                 mol_to_first_atom=first_atom_of_frag, &
                                 mol_to_last_atom=last_atom_of_frag, &
                                 mol_to_charge=charge_of_frag, &
                                 mol_to_multiplicity=multip_of_frag)

      CALL calcs_on_isolated_molecules(force_env, globenv, nmols, &
                                       first_atom_of_frag, last_atom_of_frag, charge_of_frag, multip_of_frag)

      DEALLOCATE (first_atom_of_frag)
      DEALLOCATE (last_atom_of_frag)
      DEALLOCATE (charge_of_frag)
      DEALLOCATE (multip_of_frag)

   END SUBROUTINE loop_over_molecules

! **************************************************************************************************
!> \brief Run calculations on isolated molecules. The ideas for setting up
!>        the calculations are borrowed from BSSE files
!> \param force_env ...
!> \param globenv ...
!> \param nfrags ...
!> \param first_atom_of_frag ...
!> \param last_atom_of_frag ...
!> \param charge_of_frag ...
!> \param multip_of_frag ...
!> \par   History
!>        10.2014 created
!>        09.2018 ALMO smearing support, and ALMO diag+molecular_guess patch [Ruben Staub]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE calcs_on_isolated_molecules(force_env, globenv, nfrags, &
                                          first_atom_of_frag, last_atom_of_frag, charge_of_frag, multip_of_frag)

      TYPE(force_env_type), POINTER                      :: force_env
      TYPE(global_environment_type), POINTER             :: globenv
      INTEGER, INTENT(IN)                                :: nfrags
      INTEGER, DIMENSION(:), INTENT(IN)                  :: first_atom_of_frag, last_atom_of_frag, &
                                                            charge_of_frag, multip_of_frag

      CHARACTER(LEN=*), PARAMETER :: routineN = 'calcs_on_isolated_molecules'

      CHARACTER(LEN=default_string_length)               :: name
      CHARACTER(LEN=default_string_length), &
         DIMENSION(:), POINTER                           :: atom_type
      INTEGER :: first_atom, force_method, global_charge, global_multpl, handle, i, ifrag, imo, &
         isize, j, k, last_atom, my_targ, nb_eigenval_stored, nmo, nmo_of_frag, nmosets_of_frag, &
         tot_added_mos, tot_isize
      INTEGER, DIMENSION(:), POINTER                     :: atom_index, atom_list
      LOGICAL                                            :: global_almo_scf_keyword, smear_almo_scf
      TYPE(almo_scf_env_type), POINTER                   :: almo_scf_env
      TYPE(cell_type), POINTER                           :: cell
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(cp_subsys_type), POINTER                      :: subsys, subsys_loc
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mos, mos_of_frag
      TYPE(molecular_scf_guess_env_type), POINTER        :: mscfg_env
      TYPE(particle_list_type), POINTER                  :: particles
      TYPE(qs_energy_type), POINTER                      :: qs_energy
      TYPE(qs_environment_type), POINTER                 :: qs_env, qs_env_loc
      TYPE(section_vals_type), POINTER                   :: dft_section, force_env_section, &
                                                            qs_section, root_section, scf_section, &
                                                            subsys_section

      CALL timeset(routineN, handle)

      NULLIFY (subsys_loc, subsys, particles, para_env, cell, atom_index, atom_type, &
               force_env_section, qs_env_loc, mscfg_env, qs_env, qs_energy)
      CALL force_env_get(force_env, force_env_section=force_env_section, &
                         qs_env=qs_env)
      CALL section_vals_val_get(force_env_section, "METHOD", i_val=force_method)
      CPASSERT(force_method .EQ. do_qs)
      root_section => force_env%root_section
      subsys_section => section_vals_get_subs_vals(force_env_section, "SUBSYS")
      dft_section => section_vals_get_subs_vals(force_env_section, "DFT")
      !
      ! Save several global settings to restore them after the loop:
      !  charge, multiplicity, ALMO flag
      !
      CALL section_vals_val_get(dft_section, "CHARGE", i_val=global_charge)
      CALL section_vals_val_get(dft_section, "MULTIPLICITY", i_val=global_multpl)
      qs_section => section_vals_get_subs_vals(dft_section, "QS")
      CALL section_vals_val_get(qs_section, "ALMO_SCF", l_val=global_almo_scf_keyword)
      !
      ! Get access to critical data before the loop
      !
      CALL force_env_get(force_env=force_env, subsys=subsys, para_env=para_env, &
                         cell=cell)
      CALL cp_subsys_get(subsys, particles=particles)
      CALL get_qs_env(qs_env, mscfg_env=mscfg_env, almo_scf_env=almo_scf_env)
      CPASSERT(ASSOCIATED(mscfg_env))
      IF (global_almo_scf_keyword) THEN !! Check if smearing is on, and retrieve smearing parameters accordingly
         smear_almo_scf = qs_env%scf_control%smear%do_smear
         IF (smear_almo_scf) THEN
            scf_section => section_vals_get_subs_vals(dft_section, "SCF")
            CALL section_vals_val_get(scf_section, "added_mos", i_val=tot_added_mos) !! Get total number of added MOs
            tot_isize = last_atom_of_frag(nfrags) - first_atom_of_frag(1) + 1 !! Get total number of atoms (assume consecutive atoms)
            !! Check that number of added MOs matches the number of atoms
            !! (to ensure compatibility, since each fragment will be computed with such parameters)
            IF (tot_isize .NE. tot_added_mos) THEN
               CPABORT("ALMO smearing currently requires ADDED_MOS == total number of atoms")
            END IF
            !! Get total number of MOs
            CALL get_qs_env(qs_env, mos=mos)
            IF (SIZE(mos) .GT. 1) CPABORT("Unrestricted ALMO methods are NYI") !! Unrestricted ALMO is not implemented yet
            CALL get_mo_set(mo_set=mos(1), nmo=nmo)
            !! Initialize storage of MO energies for ALMO smearing
            CPASSERT(ASSOCIATED(almo_scf_env))
            ALLOCATE (almo_scf_env%mo_energies(nmo, SIZE(mos)))
            ALLOCATE (almo_scf_env%kTS(SIZE(mos)))
            nb_eigenval_stored = 0 !! Keep track of how many eigenvalues were stored in mo_energies
         END IF
      ELSE
         smear_almo_scf = .FALSE.
      END IF
      !
      ! These flags determine the options of molecular runs (e.g. cell size)
      !
      !!!LATER is_fast_dirty = mscfg_env%is_fast_dirty - shrink the cell
      !!!LATER is_crystal = mscfg_env%is_crystal - remove periodicity
      !
      ! Prepare storage for the results
      ! Until molecular_scf_guess_env is destroyed it will keep
      ! the results of fragment calculations
      !
      CALL molecular_scf_guess_env_init(mscfg_env, nfrags)

      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      !
      ! Start the loop over molecules
      !
      ! Here is the list of modifications necessary to run isolated molecules:
      ! * Atom list of a subsystem and their names
      ! * Charge and multiplicity of a subsystem
      ! * ALMO SCF flag off (unless several levels of recursion is desired)
      ! * Smaller cell can be provided if a fast-and-dirty approach is ok
      ! * Set ADDED_MOS to number of atoms in the fragment, if smearing requested (VASP default)
      ! * ... add your own and explain it here ...
      !
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      DO ifrag = 1, nfrags
         !
         ! Turn ALMO SCF flag off
         !
         CALL section_vals_val_set(qs_section, "ALMO_SCF", l_val=.FALSE.)
         !
         ! Setup the charge and multiplicity of the molecule
         !
         CALL section_vals_val_set(dft_section, "CHARGE", i_val=charge_of_frag(ifrag))
         CALL section_vals_val_set(dft_section, "MULTIPLICITY", i_val=multip_of_frag(ifrag))
         !
         ! Create a list of atoms in the current molecule
         !
         ! Assume that atoms arranged consecutively (in ALMO SCF it is always the case)
         ! It is important to have a linear scaling procedure here
         first_atom = first_atom_of_frag(ifrag)
         last_atom = last_atom_of_frag(ifrag)
         isize = last_atom - first_atom + 1
         ALLOCATE (atom_index(isize))
         atom_index(1:isize) = (/(i, i=first_atom, last_atom)/)
         !
         ! Get atom type names
         !
         ALLOCATE (atom_type(isize))
         DO j = 1, isize
            my_targ = atom_index(j)
            DO k = 1, SIZE(particles%els)
               CALL get_atomic_kind(particles%els(k)%atomic_kind, atom_list=atom_list, name=name)
               IF (ANY(atom_list == my_targ)) EXIT
            END DO
            atom_type(j) = name
         END DO
         !
         ! If smearing requested, setup ADDED_MOS correctly for each fragment (i.e. number of atoms in fragment)
         !
         IF (smear_almo_scf) THEN
            CALL section_vals_val_set(scf_section, "added_mos", i_val=isize)
         END IF
         !
         ! Create the environment of a subsystem
         !
         CALL create_small_subsys(subsys_loc, big_subsys=subsys, &
                                  small_para_env=para_env, small_cell=cell, sub_atom_index=atom_index, &
                                  sub_atom_kind_name=atom_type, para_env=para_env, &
                                  force_env_section=force_env_section, subsys_section=subsys_section)
         ALLOCATE (qs_env_loc)
         CALL qs_env_create(qs_env_loc, globenv)
         CALL qs_init(qs_env_loc, para_env, root_section, globenv=globenv, cp_subsys=subsys_loc, &
                      force_env_section=force_env_section, subsys_section=subsys_section, &
                      use_motion_section=.FALSE.)
         CALL cp_subsys_release(subsys_loc)

         !
         ! Print-out fragment info
         !
         CALL print_frag_info(atom_index, atom_type, ifrag, nfrags, &
                              charge_of_frag(ifrag), multip_of_frag(ifrag))
         !
         !  Run calculations on a subsystem
         !
         CALL qs_energies(qs_env_loc)
         !
         !  Get the desired results (energy and MOs) out
         !
         CALL get_qs_env(qs_env_loc, mos=mos_of_frag, energy=qs_energy)
         !
         ! Store all desired results of fragment calculations in the fragment_env
         ! of the qs_env to use them later as needed
         !
         mscfg_env%energy_of_frag(ifrag) = qs_energy%total
         nmosets_of_frag = SIZE(mos_of_frag)
         CPASSERT(nmosets_of_frag .LE. mscfg_max_moset_size)
         mscfg_env%nmosets_of_frag(ifrag) = nmosets_of_frag
         DO imo = 1, nmosets_of_frag
            !! Forcing compatibility for ALMO smearing
            IF (global_almo_scf_keyword) THEN
               !! Manually add compatibility between ALMO SCF and diag SCF (used for smearing compatibility)
               !! MOs are required to compute ALMO orbitals, but not stored with diag SCF algorithm...
               !! RS-WARNING: Should be properly fixed, this is just a raw fix.
               CALL copy_fm_to_dbcsr(mos_of_frag(imo)%mo_coeff, &
                                     mos_of_frag(imo)%mo_coeff_b)
               IF (smear_almo_scf) THEN
                  !! Store MOs energies for ALMO smearing purpose
                  nmo_of_frag = SIZE(mos_of_frag(imo)%eigenvalues)
                  almo_scf_env%mo_energies(nb_eigenval_stored + 1:nb_eigenval_stored + nmo_of_frag, imo) &
                     = mos_of_frag(imo)%eigenvalues(:)
                  !! update stored energies offset. Assumes nmosets_of_frag == 1 (general smearing ALMO assumption)
                  nb_eigenval_stored = nb_eigenval_stored + nmo_of_frag
               END IF
            END IF !! ALMO

            ! the matrices have been allocated already - copy the results there
            CALL dbcsr_create(mscfg_env%mos_of_frag(ifrag, imo), &
                              template=mos_of_frag(imo)%mo_coeff_b, &
                              matrix_type=dbcsr_type_no_symmetry)
            CALL dbcsr_copy(mscfg_env%mos_of_frag(ifrag, imo), &
                            mos_of_frag(imo)%mo_coeff_b)
         END DO
         !
         ! Clean up
         !
         NULLIFY (qs_energy)
         CALL qs_env_release(qs_env_loc)
         DEALLOCATE (qs_env_loc)
         DEALLOCATE (atom_index)
         DEALLOCATE (atom_type)

      END DO

      CALL section_vals_val_set(dft_section, "CHARGE", i_val=global_charge)
      CALL section_vals_val_set(dft_section, "MULTIPLICITY", i_val=global_multpl)
      CALL section_vals_val_set(qs_section, "ALMO_SCF", l_val=global_almo_scf_keyword)

      CALL timestop(handle)

   END SUBROUTINE calcs_on_isolated_molecules

! **************************************************************************************************
!> \brief Print info about fragment
!> \param atom_index ...
!> \param atom_type ...
!> \param frag ...
!> \param nfrags ...
!> \param charge ...
!> \param multpl ...
!> \par History
!>      07.2005 created as a part of BSSE calculations [tlaino]
!>      10.2014 adapted to ALMO guess calculations [Rustam Z Khaliullin]
!> \author Rustam Z Khaliullin
! **************************************************************************************************
   SUBROUTINE print_frag_info(atom_index, atom_type, frag, nfrags, charge, &
                              multpl)

      INTEGER, DIMENSION(:), POINTER                     :: atom_index
      CHARACTER(len=default_string_length), &
         DIMENSION(:), POINTER                           :: atom_type
      INTEGER, INTENT(IN)                                :: frag, nfrags, charge, multpl

      CHARACTER(len=11)                                  :: charI
      INTEGER                                            :: i, iw
      TYPE(cp_logger_type), POINTER                      :: logger

      NULLIFY (logger)
      logger => cp_get_default_logger()
      IF (logger%para_env%ionode) THEN
         iw = cp_logger_get_default_unit_nr(logger, local=.TRUE.)
      ELSE
         iw = -1
      END IF

      IF (iw > 0) THEN

         WRITE (UNIT=iw, FMT="(/,T2,A)") REPEAT("-", 79)
         WRITE (UNIT=iw, FMT="(T2,A,T80,A)") "-", "-"
         WRITE (UNIT=iw, FMT="(T2,A,T5,A,T25,A,T40,I11,T53,A,T67,I11,T80,A)") &
            "-", "MOLECULAR GUESS:", "FRAGMENT", frag, "OUT OF", nfrags, "-"
         WRITE (UNIT=iw, FMT="(T2,A,T25,A,T40,I11,T53,A,T67,I11,T80,A)") "-", "CHARGE", charge, "MULTIPLICITY", &
            multpl, "-"
         WRITE (UNIT=iw, FMT="(T2,A,T80,A)") "-", "-"
         WRITE (UNIT=iw, FMT="(T2,A,T25,A,T53,A,T80,A)") "-", "ATOM INDEX", "ATOM NAME", "-"
         WRITE (UNIT=iw, FMT="(T2,A,T25,A,T53,A,T80,A)") "-", "----------", "---------", "-"
         DO i = 1, SIZE(atom_index)
            WRITE (charI, '(I11)') atom_index(i)
            WRITE (UNIT=iw, FMT="(T2,A,T25,A,T53,A,T80,A)") "-", ADJUSTL(charI), TRIM(atom_type(i)), "-"
         END DO
         WRITE (UNIT=iw, FMT="(T2,A)") REPEAT("-", 79)
      END IF

   END SUBROUTINE print_frag_info

! **************************************************************************************************
!> \brief Is the loop over molecules requested?
!> \param force_env ...
!> \return ...
!> \par History
!>       10.2014 created [Rustam Z. Khaliullin]
!> \author Rustam Z. Khaliullin
! **************************************************************************************************
   FUNCTION do_mol_loop(force_env)

      TYPE(force_env_type), POINTER                      :: force_env
      LOGICAL                                            :: do_mol_loop

      INTEGER                                            :: almo_guess_type, frz_term_type, &
                                                            method_name_id, scf_guess_type
      LOGICAL                                            :: almo_scf_is_on, is_crystal, is_fast_dirty
      TYPE(molecular_scf_guess_env_type), POINTER        :: mscfg_env
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(section_vals_type), POINTER                   :: force_env_section, subsection

      do_mol_loop = .FALSE.
      ! What kind of options are we using in the loop ?
      is_fast_dirty = .TRUE.
      is_crystal = .FALSE.
      almo_scf_is_on = .FALSE.

      NULLIFY (qs_env, mscfg_env, force_env_section, subsection)
      CALL force_env_get(force_env, force_env_section=force_env_section)
      CALL section_vals_val_get(force_env_section, "METHOD", i_val=method_name_id)

      IF (method_name_id .EQ. do_qs) THEN

         CALL force_env_get(force_env, qs_env=qs_env)
         CPASSERT(ASSOCIATED(qs_env))

         CALL get_qs_env(qs_env, mscfg_env=mscfg_env)
         CPASSERT(ASSOCIATED(mscfg_env))

         !!!! RZK-warning: All decisions are based on the values of input keywords
         !!!! The real danger is that many of these keywords might not be even
         !!!! in control of the job. They might be simply present in the input
         !!!! This section must be re-written more accurately

         ! check ALMO SCF guess option
         NULLIFY (subsection)
         subsection => section_vals_get_subs_vals(force_env_section, "DFT%ALMO_SCF")
         CALL section_vals_val_get(subsection, "ALMO_SCF_GUESS", i_val=almo_guess_type)
         ! check whether ALMO SCF is on
         NULLIFY (subsection)
         subsection => section_vals_get_subs_vals(force_env_section, "DFT%QS")
         CALL section_vals_val_get(subsection, "ALMO_SCF", l_val=almo_scf_is_on)

         ! check SCF guess option
         NULLIFY (subsection)
         subsection => section_vals_get_subs_vals(force_env_section, "DFT%SCF")
         CALL section_vals_val_get(subsection, "SCF_GUESS", i_val=scf_guess_type)

         ! check ALMO EDA options
         NULLIFY (subsection)
         !!!LATER subsection    => section_vals_get_subs_vals(force_env_section,"DFT%ALMO_SCF%ALMO_DA")
         !!!LATER CALL section_vals_val_get(subsection,"FRZ_TERM",i_val=frz_term_type)
         frz_term_type = almo_frz_none

         ! Are we doing the loop ?
         IF (scf_guess_type .EQ. molecular_guess .OR. & ! SCF guess is molecular
             (almo_guess_type .EQ. molecular_guess .AND. almo_scf_is_on) .OR. & ! ALMO SCF guess is molecular
             frz_term_type .NE. almo_frz_none) THEN ! ALMO FRZ term is requested

            do_mol_loop = .TRUE.

            ! If we are calculating molecular guess it is OK to do fast and dirty loop
            ! It is NOT ok to be sloppy with ALMO EDA calculations of the FRZ term
            IF (frz_term_type .NE. almo_frz_none) THEN
               is_fast_dirty = .FALSE.
               IF (frz_term_type .EQ. almo_frz_crystal) THEN
                  is_crystal = .TRUE.
               END IF
            END IF

         END IF

         mscfg_env%is_fast_dirty = is_fast_dirty
         mscfg_env%is_crystal = is_crystal

      END IF

      RETURN

   END FUNCTION do_mol_loop

END MODULE mscfg_methods

