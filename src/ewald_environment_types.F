!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \par History
!>      JGH FEB-13-2007 : Distributed/replicated realspace grids
!>      Teodoro Laino [tlaino] - University of Zurich - 12.2007
!> \author CJM NOV-30-2003
! **************************************************************************************************
MODULE ewald_environment_types
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE cp_para_env,                     ONLY: cp_para_env_release,&
                                              cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_units,                        ONLY: cp_unit_from_cp2k
   USE input_cp2k_poisson,              ONLY: create_ewald_section
   USE input_enumeration_types,         ONLY: enum_i2c,&
                                              enumeration_type
   USE input_keyword_types,             ONLY: keyword_get,&
                                              keyword_type
   USE input_section_types,             ONLY: section_get_keyword,&
                                              section_release,&
                                              section_type,&
                                              section_vals_get_subs_vals,&
                                              section_vals_release,&
                                              section_vals_retain,&
                                              section_vals_type,&
                                              section_vals_val_get
   USE kinds,                           ONLY: dp
   USE mathconstants,                   ONLY: twopi
   USE message_passing,                 ONLY: mp_comm_type
   USE pw_grid_info,                    ONLY: pw_grid_n_for_fft
   USE pw_poisson_types,                ONLY: do_ewald_ewald,&
                                              do_ewald_none,&
                                              do_ewald_pme,&
                                              do_ewald_spme
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

! **************************************************************************************************
!> \brief to build arrays of pointers
!> \param ewald_env the pointer to the ewald_env
!> \par History
!>      11/03
!> \author CJM
! **************************************************************************************************
   TYPE ewald_environment_type
      PRIVATE
      LOGICAL   :: do_multipoles ! Flag for using the multipole code
      INTEGER   :: do_ipol ! Solver for induced dipoles
      INTEGER   :: max_multipole ! max expansion in the multipoles
      INTEGER   :: max_ipol_iter ! max number of interaction for induced dipoles
      INTEGER   :: ewald_type ! type of ewald
      INTEGER   :: gmax(3) ! max Miller index
      INTEGER   :: ns_max ! # grid points for small grid (PME)
      INTEGER   :: o_spline ! order of spline (SPME)
      REAL(KIND=dp) :: precs ! precision achieved when evaluating the real-space part
      REAL(KIND=dp) :: alpha, rcut ! ewald alpha and real-space cutoff
      REAL(KIND=dp) :: epsilon ! tolerance for small grid (PME)
      REAL(KIND=dp) :: eps_pol ! tolerance for convergence of induced dipoles
      TYPE(cp_para_env_type), POINTER          :: para_env
      TYPE(section_vals_type), POINTER         :: poisson_section
      ! interaction cutoff is required to make the electrostatic interaction
      ! continuous at a pair distance equal to rcut. this is ignored by the
      ! multipole code and is otherwise only active when SHIFT_CUTOFF is used.
      REAL(KIND=dp), DIMENSION(:, :, :), POINTER :: interaction_cutoffs
      ! store current cell, used to rebuild lazily.
      REAL(KIND=dp), DIMENSION(3, 3)          :: cell_hmat = -1.0_dp
   END TYPE ewald_environment_type

! *** Public data types ***
   PUBLIC :: ewald_environment_type

! *** Public subroutines ***
   PUBLIC :: ewald_env_get, &
             ewald_env_set, &
             ewald_env_create, &
             ewald_env_release, &
             read_ewald_section, &
             read_ewald_section_tb

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'ewald_environment_types'

CONTAINS

! **************************************************************************************************
!> \brief Purpose: Get the EWALD environment.
!> \param ewald_env the pointer to the ewald_env
!> \param ewald_type ...
!> \param alpha ...
!> \param eps_pol ...
!> \param epsilon ...
!> \param gmax ...
!> \param ns_max ...
!> \param o_spline ...
!> \param group ...
!> \param para_env ...
!> \param poisson_section ...
!> \param precs ...
!> \param rcut ...
!> \param do_multipoles ...
!> \param max_multipole ...
!> \param do_ipol ...
!> \param max_ipol_iter ...
!> \param interaction_cutoffs ...
!> \param cell_hmat ...
!> \par History
!>      11/03
!> \author CJM
! **************************************************************************************************
   SUBROUTINE ewald_env_get(ewald_env, ewald_type, alpha, eps_pol, epsilon, &
                            gmax, ns_max, o_spline, group, para_env, poisson_section, precs, &
                            rcut, do_multipoles, max_multipole, do_ipol, max_ipol_iter, &
                            interaction_cutoffs, cell_hmat)
      TYPE(ewald_environment_type), INTENT(IN)           :: ewald_env
      INTEGER, OPTIONAL                                  :: ewald_type
      REAL(KIND=dp), OPTIONAL                            :: alpha, eps_pol, epsilon
      INTEGER, OPTIONAL                                  :: gmax(3), ns_max, o_spline
      TYPE(mp_comm_type), INTENT(OUT), OPTIONAL          :: group
      TYPE(cp_para_env_type), OPTIONAL, POINTER          :: para_env
      TYPE(section_vals_type), OPTIONAL, POINTER         :: poisson_section
      REAL(KIND=dp), OPTIONAL                            :: precs, rcut
      LOGICAL, INTENT(OUT), OPTIONAL                     :: do_multipoles
      INTEGER, INTENT(OUT), OPTIONAL                     :: max_multipole, do_ipol, max_ipol_iter
      REAL(KIND=dp), DIMENSION(:, :, :), OPTIONAL, &
         POINTER                                         :: interaction_cutoffs
      REAL(KIND=dp), DIMENSION(3, 3), OPTIONAL           :: cell_hmat

      IF (PRESENT(ewald_type)) ewald_type = ewald_env%ewald_type
      IF (PRESENT(do_multipoles)) do_multipoles = ewald_env%do_multipoles
      IF (PRESENT(do_ipol)) do_ipol = ewald_env%do_ipol
      IF (PRESENT(max_multipole)) max_multipole = ewald_env%max_multipole
      IF (PRESENT(max_ipol_iter)) max_ipol_iter = ewald_env%max_ipol_iter
      IF (PRESENT(alpha)) alpha = ewald_env%alpha
      IF (PRESENT(precs)) precs = ewald_env%precs
      IF (PRESENT(rcut)) rcut = ewald_env%rcut
      IF (PRESENT(epsilon)) epsilon = ewald_env%epsilon
      IF (PRESENT(eps_pol)) eps_pol = ewald_env%eps_pol
      IF (PRESENT(gmax)) gmax = ewald_env%gmax
      IF (PRESENT(ns_max)) ns_max = ewald_env%ns_max
      IF (PRESENT(o_spline)) o_spline = ewald_env%o_spline
      IF (PRESENT(group)) group = ewald_env%para_env%group
      IF (PRESENT(para_env)) para_env => ewald_env%para_env
      IF (PRESENT(poisson_section)) poisson_section => ewald_env%poisson_section
      IF (PRESENT(interaction_cutoffs)) interaction_cutoffs => &
         ewald_env%interaction_cutoffs
      IF (PRESENT(cell_hmat)) cell_hmat = ewald_env%cell_hmat
   END SUBROUTINE ewald_env_get

! **************************************************************************************************
!> \brief Purpose: Set the EWALD environment.
!> \param ewald_env the pointer to the ewald_env
!> \param ewald_type ...
!> \param alpha ...
!> \param epsilon ...
!> \param eps_pol ...
!> \param gmax ...
!> \param ns_max ...
!> \param precs ...
!> \param o_spline ...
!> \param para_env ...
!> \param poisson_section ...
!> \param interaction_cutoffs ...
!> \param cell_hmat ...
!> \par History
!>      11/03
!> \author CJM
! **************************************************************************************************
   SUBROUTINE ewald_env_set(ewald_env, ewald_type, alpha, epsilon, eps_pol, &
                            gmax, ns_max, precs, o_spline, para_env, poisson_section, &
                            interaction_cutoffs, cell_hmat)

      TYPE(ewald_environment_type), INTENT(INOUT)        :: ewald_env
      INTEGER, OPTIONAL                                  :: ewald_type
      REAL(KIND=dp), OPTIONAL                            :: alpha, epsilon, eps_pol
      INTEGER, OPTIONAL                                  :: gmax(3), ns_max
      REAL(KIND=dp), OPTIONAL                            :: precs
      INTEGER, OPTIONAL                                  :: o_spline
      TYPE(cp_para_env_type), OPTIONAL, POINTER          :: para_env
      TYPE(section_vals_type), OPTIONAL, POINTER         :: poisson_section
      REAL(KIND=dp), DIMENSION(:, :, :), OPTIONAL, &
         POINTER                                         :: interaction_cutoffs
      REAL(KIND=dp), DIMENSION(3, 3), OPTIONAL           :: cell_hmat

      IF (PRESENT(ewald_type)) ewald_env%ewald_type = ewald_type
      IF (PRESENT(alpha)) ewald_env%alpha = alpha
      IF (PRESENT(precs)) ewald_env%precs = precs
      IF (PRESENT(epsilon)) ewald_env%epsilon = epsilon
      IF (PRESENT(eps_pol)) ewald_env%eps_pol = eps_pol
      IF (PRESENT(gmax)) ewald_env%gmax = gmax
      IF (PRESENT(ns_max)) ewald_env%ns_max = ns_max
      IF (PRESENT(o_spline)) ewald_env%o_spline = o_spline
      IF (PRESENT(para_env)) ewald_env%para_env => para_env
      IF (PRESENT(poisson_section)) THEN
         CALL section_vals_retain(poisson_section)
         CALL section_vals_release(ewald_env%poisson_section)
         ewald_env%poisson_section => poisson_section
      END IF
      IF (PRESENT(interaction_cutoffs)) ewald_env%interaction_cutoffs => &
         interaction_cutoffs
      IF (PRESENT(cell_hmat)) ewald_env%cell_hmat = cell_hmat
   END SUBROUTINE ewald_env_set

! **************************************************************************************************
!> \brief allocates and intitializes a ewald_env
!> \param ewald_env the object to create
!> \param para_env ...
!> \par History
!>      12.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE ewald_env_create(ewald_env, para_env)
      TYPE(ewald_environment_type), INTENT(OUT)          :: ewald_env
      TYPE(cp_para_env_type), POINTER                    :: para_env

      NULLIFY (ewald_env%poisson_section)
      CALL cp_para_env_retain(para_env)
      ewald_env%para_env => para_env
      NULLIFY (ewald_env%interaction_cutoffs) ! allocated and initialized later
   END SUBROUTINE ewald_env_create

! **************************************************************************************************
!> \brief releases the given ewald_env (see doc/ReferenceCounting.html)
!> \param ewald_env the object to release
!> \par History
!>      12.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE ewald_env_release(ewald_env)
      TYPE(ewald_environment_type), INTENT(INOUT)        :: ewald_env

      CALL cp_para_env_release(ewald_env%para_env)
      CALL section_vals_release(ewald_env%poisson_section)
      IF (ASSOCIATED(ewald_env%interaction_cutoffs)) THEN
         DEALLOCATE (ewald_env%interaction_cutoffs)
      END IF

   END SUBROUTINE ewald_env_release

! **************************************************************************************************
!> \brief Purpose: read the EWALD section
!> \param ewald_env the pointer to the ewald_env
!> \param ewald_section ...
!> \author Teodoro Laino [tlaino] -University of Zurich - 2005
! **************************************************************************************************
   SUBROUTINE read_ewald_section(ewald_env, ewald_section)
      TYPE(ewald_environment_type), INTENT(INOUT)        :: ewald_env
      TYPE(section_vals_type), POINTER                   :: ewald_section

      INTEGER                                            :: iw
      INTEGER, DIMENSION(:), POINTER                     :: gmax_read
      LOGICAL                                            :: explicit
      REAL(KIND=dp)                                      :: dummy
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(enumeration_type), POINTER                    :: enum
      TYPE(keyword_type), POINTER                        :: keyword
      TYPE(section_type), POINTER                        :: section
      TYPE(section_vals_type), POINTER                   :: multipole_section

      NULLIFY (enum, keyword, section, multipole_section)
      logger => cp_get_default_logger()
      CALL section_vals_val_get(ewald_section, "EWALD_TYPE", i_val=ewald_env%ewald_type)
      CALL section_vals_val_get(ewald_section, "ALPHA", r_val=ewald_env%alpha)
      CALL section_vals_val_get(ewald_section, "EWALD_ACCURACY", r_val=ewald_env%precs)

      IF (ewald_env%ewald_type == do_ewald_none) THEN
         ewald_env%rcut = 0.0_dp
      ELSE
         CALL section_vals_val_get(ewald_section, "RCUT", explicit=explicit)
         IF (explicit) THEN
            CALL section_vals_val_get(ewald_section, "RCUT", r_val=ewald_env%rcut)
         ELSE
            ewald_env%rcut = find_ewald_optimal_value(ewald_env%precs)/ewald_env%alpha
         END IF
      END IF
      ! we have no defaults for gmax, gmax is only needed for ewald and spme
      SELECT CASE (ewald_env%ewald_type)
      CASE (do_ewald_ewald, do_ewald_spme)
         CALL section_vals_val_get(ewald_section, "GMAX", i_vals=gmax_read)
         SELECT CASE (SIZE(gmax_read, 1))
         CASE (1)
            ewald_env%gmax = gmax_read(1)
         CASE (3)
            ewald_env%gmax = gmax_read
         CASE DEFAULT
            CPABORT("")
         END SELECT
         IF (ewald_env%ewald_type == do_ewald_spme) THEN
            CALL section_vals_val_get(ewald_section, "O_SPLINE", i_val=ewald_env%o_spline)
         END IF
      CASE (do_ewald_pme)
         CALL section_vals_val_get(ewald_section, "NS_MAX", i_val=ewald_env%ns_max)
         CALL section_vals_val_get(ewald_section, "EPSILON", r_val=ewald_env%epsilon)
      CASE DEFAULT
         ! this should not be used for do_ewald_none
         ewald_env%gmax = HUGE(0)
         ewald_env%ns_max = HUGE(0)
      END SELECT

      ! Multipoles
      multipole_section => section_vals_get_subs_vals(ewald_section, "MULTIPOLES")
      CALL section_vals_val_get(multipole_section, "_SECTION_PARAMETERS_", l_val=ewald_env%do_multipoles)
      CALL section_vals_val_get(multipole_section, "POL_SCF", i_val=ewald_env%do_ipol)
      CALL section_vals_val_get(multipole_section, "EPS_POL", r_val=ewald_env%eps_pol)
      IF (ewald_env%do_multipoles) THEN
         SELECT CASE (ewald_env%ewald_type)
         CASE (do_ewald_ewald)
            CALL section_vals_val_get(multipole_section, "MAX_MULTIPOLE_EXPANSION", &
                                      i_val=ewald_env%max_multipole)
            CALL section_vals_val_get(multipole_section, "MAX_IPOL_ITER", i_val=ewald_env%max_ipol_iter)
         CASE DEFAULT
            CPABORT("Multipole code works at the moment only with standard EWALD sums.")
         END SELECT
      END IF

      iw = cp_print_key_unit_nr(logger, ewald_section, "PRINT%PROGRAM_RUN_INFO", &
                                extension=".log")
      IF (iw > 0) THEN
         NULLIFY (keyword, enum)
         CALL create_ewald_section(section)
         IF (ewald_env%ewald_type /= do_ewald_none) THEN
            keyword => section_get_keyword(section, "EWALD_TYPE")
            CALL keyword_get(keyword, enum=enum)
            WRITE (iw, '(/,T2,"EWALD| ",A,T67,A14 )') 'Summation is done by:', &
               ADJUSTR(TRIM(enum_i2c(enum, ewald_env%ewald_type)))
            IF (ewald_env%do_multipoles) THEN
               NULLIFY (keyword, enum)
               keyword => section_get_keyword(section, "MULTIPOLES%MAX_MULTIPOLE_EXPANSION")
               CALL keyword_get(keyword, enum=enum)
               WRITE (iw, '( T2,"EWALD| ",A )') 'Enabled Multipole Method'
               WRITE (iw, '( T2,"EWALD| ",A,T67,A14 )') 'Max Term in Multipole Expansion :', &
                  ADJUSTR(TRIM(enum_i2c(enum, ewald_env%max_multipole)))
               WRITE (iw, '( T2,"EWALD| ",A,T67,3I10 )') 'Max number Iterations for IPOL :', &
                  ewald_env%max_ipol_iter
            END IF
            dummy = cp_unit_from_cp2k(ewald_env%alpha, "angstrom^-1")
            WRITE (iw, '( T2,"EWALD| ",A,A18,A,T71,F10.4 )') &
               'Alpha parameter [', 'ANGSTROM^-1', ']', dummy
            dummy = cp_unit_from_cp2k(ewald_env%rcut, "angstrom")
            WRITE (iw, '( T2,"EWALD| ",A,A18,A,T71,F10.4 )') &
               'Real Space Cutoff [', 'ANGSTROM', ']', dummy

            SELECT CASE (ewald_env%ewald_type)
            CASE (do_ewald_ewald)
               WRITE (iw, '( T2,"EWALD| ",A,T51,3I10 )') &
                  'G-space max. Miller index', ewald_env%gmax
            CASE (do_ewald_pme)
               WRITE (iw, '( T2,"EWALD| ",A,T71,I10 )') &
                  'Max small-grid points (input) ', ewald_env%ns_max
               WRITE (iw, '( T2,"EWALD| ",A,T71,E10.4 )') &
                  'Gaussian tolerance (input) ', ewald_env%epsilon
            CASE (do_ewald_spme)
               WRITE (iw, '( T2,"EWALD| ",A,T51,3I10 )') &
                  'G-space max. Miller index', ewald_env%gmax
               WRITE (iw, '( T2,"EWALD| ",A,T71,I10 )') &
                  'Spline interpolation order ', ewald_env%o_spline
            CASE DEFAULT
               CPABORT("")
            END SELECT
         ELSE
            WRITE (iw, '( T2,"EWALD| ",T73, A )') 'not used'
         END IF
         CALL section_release(section)
      END IF
      CALL cp_print_key_finished_output(iw, logger, ewald_section, &
                                        "PRINT%PROGRAM_RUN_INFO")

   END SUBROUTINE read_ewald_section

! **************************************************************************************************
!> \brief Purpose: read the EWALD section for TB methods
!> \param ewald_env the pointer to the ewald_env
!> \param ewald_section ...
!> \param hmat ...
!> \author JGH
! **************************************************************************************************
   SUBROUTINE read_ewald_section_tb(ewald_env, ewald_section, hmat)
      TYPE(ewald_environment_type), INTENT(INOUT)        :: ewald_env
      TYPE(section_vals_type), POINTER                   :: ewald_section
      REAL(KIND=dp), DIMENSION(3, 3), INTENT(IN)         :: hmat

      INTEGER                                            :: i, iw, n(3)
      INTEGER, DIMENSION(:), POINTER                     :: gmax_read
      LOGICAL                                            :: explicit
      REAL(KIND=dp)                                      :: alat, cutoff, dummy
      TYPE(cp_logger_type), POINTER                      :: logger

      logger => cp_get_default_logger()

      ewald_env%do_multipoles = .FALSE.
      ewald_env%do_ipol = 0
      ewald_env%eps_pol = 1.e-12_dp
      ewald_env%max_multipole = 0
      ewald_env%max_ipol_iter = 0
      ewald_env%epsilon = 1.e-12_dp
      ewald_env%ns_max = HUGE(0)

      CALL section_vals_val_get(ewald_section, "EWALD_TYPE", explicit=explicit)
      IF (explicit) THEN
         CALL section_vals_val_get(ewald_section, "EWALD_TYPE", i_val=ewald_env%ewald_type)
         IF (ewald_env%ewald_type /= do_ewald_spme) THEN
            CPABORT("TB needs EWALD_TYPE SPME")
         END IF
      ELSE
         ewald_env%ewald_type = do_ewald_spme
      END IF

      CALL section_vals_val_get(ewald_section, "ALPHA", explicit=explicit)
      IF (explicit) THEN
         CALL section_vals_val_get(ewald_section, "ALPHA", r_val=ewald_env%alpha)
      ELSE
         ewald_env%alpha = 1.0_dp
      END IF

      CALL section_vals_val_get(ewald_section, "EWALD_ACCURACY", r_val=ewald_env%precs)
      CALL section_vals_val_get(ewald_section, "O_SPLINE", i_val=ewald_env%o_spline)

      CALL section_vals_val_get(ewald_section, "RCUT", explicit=explicit)
      IF (explicit) THEN
         CALL section_vals_val_get(ewald_section, "RCUT", r_val=ewald_env%rcut)
      ELSE
         ewald_env%rcut = find_ewald_optimal_value(ewald_env%precs)/ewald_env%alpha
      END IF

      CALL section_vals_val_get(ewald_section, "GMAX", explicit=explicit)
      IF (explicit) THEN
         CALL section_vals_val_get(ewald_section, "GMAX", i_vals=gmax_read)
         SELECT CASE (SIZE(gmax_read, 1))
         CASE (1)
            ewald_env%gmax = gmax_read(1)
         CASE (3)
            ewald_env%gmax = gmax_read
         CASE DEFAULT
            CPABORT("")
         END SELECT
      ELSE
         ! set GMAX using ECUT=alpha*45 Ry
         cutoff = 45._dp*ewald_env%alpha
         DO i = 1, 3
            alat = SUM(hmat(:, i)**2)
            CPASSERT(alat /= 0._dp)
            ewald_env%gmax(i) = 2*FLOOR(SQRT(2.0_dp*cutoff*alat)/twopi) + 1
         END DO
      END IF
      n = ewald_env%gmax
      ewald_env%gmax = pw_grid_n_for_fft(n, odd=.TRUE.)

      iw = cp_print_key_unit_nr(logger, ewald_section, "PRINT%PROGRAM_RUN_INFO", &
                                extension=".log")
      IF (iw > 0) THEN
         WRITE (iw, '(/,T2,"EWALD| ",A,T67,A14 )') 'Summation is done by:', ADJUSTR("SPME")
         dummy = cp_unit_from_cp2k(ewald_env%alpha, "angstrom^-1")
         WRITE (iw, '( T2,"EWALD| ",A,A18,A,T71,F10.4 )') &
            'Alpha parameter [', 'ANGSTROM^-1', ']', dummy
         dummy = cp_unit_from_cp2k(ewald_env%rcut, "angstrom")
         WRITE (iw, '( T2,"EWALD| ",A,A18,A,T71,F10.4 )') &
            'Real Space Cutoff [', 'ANGSTROM', ']', dummy
         WRITE (iw, '( T2,"EWALD| ",A,T51,3I10 )') &
            'G-space max. Miller index', ewald_env%gmax
         WRITE (iw, '( T2,"EWALD| ",A,T71,I10 )') &
            'Spline interpolation order ', ewald_env%o_spline
      END IF
      CALL cp_print_key_finished_output(iw, logger, ewald_section, &
                                        "PRINT%PROGRAM_RUN_INFO")

   END SUBROUTINE read_ewald_section_tb

! **************************************************************************************************
!> \brief triggers (by bisection) the optimal value for EWALD parameter x
!>      EXP(-x^2)/x^2 = EWALD_ACCURACY
!> \param precs ...
!> \return ...
!> \author Teodoro Laino [tlaino] - University of Zurich - 12.2007
! **************************************************************************************************
   FUNCTION find_ewald_optimal_value(precs) RESULT(value)
      REAL(KIND=dp)                                      :: precs, value

      REAL(KIND=dp)                                      :: func, func1, func2, s, s1, s2

      s = 0.1_dp
      func = EXP(-s**2)/s**2 - precs
      CPASSERT(func > 0.0_dp)
      DO WHILE (func > 0.0_dp)
         s = s + 0.1_dp
         func = EXP(-s**2)/s**2 - precs
      END DO
      s2 = s
      s1 = s - 0.1_dp
      ! Start bisection
      DO WHILE (.TRUE.)
         func2 = EXP(-s2**2)/s2**2 - precs
         func1 = EXP(-s1**2)/s1**2 - precs
         CPASSERT(func1 >= 0)
         CPASSERT(func2 <= 0)
         s = 0.5_dp*(s1 + s2)
         func = EXP(-s**2)/s**2 - precs
         IF (func > 0.0_dp) THEN
            s1 = s
         ELSE IF (func < 0.0_dp) THEN
            s2 = s
         END IF
         IF (ABS(func) < 100.0_dp*EPSILON(0.0_dp)) EXIT
      END DO
      value = s
   END FUNCTION find_ewald_optimal_value

END MODULE ewald_environment_types

