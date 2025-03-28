!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Excited state input section
!> \par History
!>      01.2020 created
!> \author jgh
! **************************************************************************************************
MODULE input_cp2k_exstate
   USE input_constants,                 ONLY: xc_kernel_method_analytic,&
                                              xc_kernel_method_best,&
                                              xc_kernel_method_numeric
   USE input_keyword_types,             ONLY: keyword_create,&
                                              keyword_release,&
                                              keyword_type
   USE input_section_types,             ONLY: section_add_keyword,&
                                              section_create,&
                                              section_type
   USE string_utilities,                ONLY: s2a
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'input_cp2k_exstate'

   PUBLIC :: create_exstate_section

CONTAINS

! **************************************************************************************************
!> \brief creates the EXCITED ENERGY section
!> \param section ...
!> \author JGH
! **************************************************************************************************
   SUBROUTINE create_exstate_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))

      NULLIFY (keyword)
      CALL section_create(section, __LOCATION__, name="EXCITED_STATES", &
                          description="Sets the various options for Excited State Potential Energy Calculations", &
                          n_keywords=1, n_subsections=0, repeats=.FALSE.)

      CALL keyword_create(keyword, __LOCATION__, name="_SECTION_PARAMETERS_", &
                          description="Controls the activation of the excited states", &
                          usage="&EXCITED_STATES T", &
                          default_l_val=.FALSE., &
                          lone_keyword_l_val=.TRUE.)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="STATE", &
                          description="Excited state to be used in calculation. Negative values indicate state following.", &
                          usage="STATE 2", &
                          default_i_val=1)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="XC_KERNEL_METHOD", &
                          description="Method to evaluate XC Kernel contributions to forces", &
                          usage="XC_KERNEL_METHOD (BEST_AVAILABLE|ANALYTIC|NUMERIC)", &
                          enum_c_vals=s2a("BEST_AVAILABLE", "ANALYTIC", "NUMERIC"), &
                          enum_i_vals=(/xc_kernel_method_best, xc_kernel_method_analytic, xc_kernel_method_numeric/), &
                          default_i_val=xc_kernel_method_best)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="OVERLAP_DELTAT", &
                          description="Keyword for the computation of the overlap matrix between two consecutive time steps.", &
                          usage="OVERLAP_DELTAT", &
                          default_l_val=.FALSE., &
                          lone_keyword_l_val=.TRUE.)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_exstate_section

END MODULE input_cp2k_exstate
