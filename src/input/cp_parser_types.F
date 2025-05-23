!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Utility routines to read data from files.
!>      Kept as close as possible to the old parser because
!>        1. string handling is a weak point of fortran compilers, and it is
!>           easy to write correct things that do not work
!>        2. conversion of old code
!> \par History
!>      22.11.1999 first version of the old parser (called qs_parser)
!>                 Matthias Krack
!>      06.2004 removed module variables, cp_parser_type, new module [fawzi]
!>      08.2008 Added buffering [tlaino]
!> \author fawzi
! **************************************************************************************************
MODULE cp_parser_types
   USE cp_files,                        ONLY: close_file,&
                                              open_file
   USE cp_para_env,                     ONLY: cp_para_env_create,&
                                              cp_para_env_release,&
                                              cp_para_env_retain
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE cp_parser_buffer_types,          ONLY: buffer_type,&
                                              create_buffer_type,&
                                              release_buffer_type
   USE cp_parser_ilist_types,           ONLY: create_ilist_type,&
                                              ilist_type,&
                                              release_ilist_type
   USE cp_parser_inpp_types,            ONLY: create_inpp_type,&
                                              inpp_type,&
                                              release_inpp_type
   USE cp_parser_status_types,          ONLY: create_status_type,&
                                              release_status_type,&
                                              status_type
   USE kinds,                           ONLY: default_path_length,&
                                              default_string_length,&
                                              max_line_length
   USE message_passing,                 ONLY: mp_comm_self
   USE string_utilities,                ONLY: compress
#include "../base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   PUBLIC :: cp_parser_type, parser_release, parser_create, &
             parser_reset, empty_initial_variables

   ! this is a zero sized array by choice, and convenience
   CHARACTER(LEN=default_path_length), DIMENSION(2, 1:0) :: empty_initial_variables

   ! Private parameters
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_parser_types'

   ! Global variables
   CHARACTER(LEN=1), PARAMETER, PUBLIC   :: default_continuation_character = CHAR(92) ! backslash
   CHARACTER(LEN=4), PARAMETER, PUBLIC   :: default_separators = ",:;="
   CHARACTER(LEN=3), PARAMETER, PUBLIC   :: default_end_section_label = "END"
   CHARACTER(LEN=1), PARAMETER, PUBLIC   :: default_comment_character(2) = (/"#", "!"/), &
                                            default_section_character = "&", &
                                            default_quote_character = '"'
   INTEGER, PARAMETER, PUBLIC            :: max_unit_number = 999

! **************************************************************************************************
!> \brief represent a parser
!> \param icol Number of the current column in the current input line,
!>  -1 if at the end of the file
!>  icol1            : First column of the current input string
!>  icol2            : Last column of the current input string
!> \param input_line_number Number of the current input line read from the input file
!> \param input_unit Logical unit number of the input file
!> \author fawzi
! **************************************************************************************************
   TYPE cp_parser_type
      CHARACTER(LEN=default_string_length)           :: end_section, start_section
      CHARACTER(LEN=10)                              :: separators
      CHARACTER(LEN=1)                               :: comment_character(2), &
                                                        continuation_character, &
                                                        quote_character, &
                                                        section_character
      CHARACTER(LEN=default_path_length)             :: input_file_name
      CHARACTER(LEN=max_line_length)                 :: input_line
      INTEGER                                        :: icol, icol1, icol2
      INTEGER                                        :: input_unit, input_line_number
      LOGICAL                                        :: first_separator, &
                                                        apply_preprocessing, &
                                                        parse_white_lines
      CHARACTER(len=default_path_length), DIMENSION(:, :), POINTER :: initial_variables
      TYPE(buffer_type), POINTER                     :: buffer
      TYPE(status_type), POINTER                     :: status
      TYPE(cp_para_env_type), POINTER                :: para_env
      TYPE(inpp_type), POINTER                       :: inpp
      TYPE(ilist_type), POINTER                      :: ilist
   END TYPE cp_parser_type

CONTAINS

! **************************************************************************************************
!> \brief   releases the parser
!> \param parser ...
!> \date    14.02.2001
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE parser_release(parser)
      TYPE(cp_parser_type), INTENT(INOUT)                :: parser

      IF (parser%input_unit >= 0) THEN
         CALL close_file(unit_number=parser%input_unit)
      END IF
      CALL cp_para_env_release(parser%para_env)
      CALL release_inpp_type(parser%inpp)
      CALL release_ilist_type(parser%ilist)
      CALL release_buffer_type(parser%buffer)
      CALL release_status_type(parser%status)
      IF (ASSOCIATED(parser%initial_variables)) THEN
         DEALLOCATE (parser%initial_variables)
      END IF

   END SUBROUTINE parser_release

! **************************************************************************************************
!> \brief   Start a parser run. Initial variables allow to @SET stuff before opening the file
!> \param parser ...
!> \param file_name ...
!> \param unit_nr ...
!> \param para_env ...
!> \param end_section_label ...
!> \param separator_chars ...
!> \param comment_char ...
!> \param continuation_char ...
!> \param quote_char ...
!> \param section_char ...
!> \param parse_white_lines ...
!> \param initial_variables ...
!> \param apply_preprocessing ...
!> \date    14.02.2001
!> \author  MK
!> \version 1.0
! **************************************************************************************************
   SUBROUTINE parser_create(parser, file_name, unit_nr, para_env, end_section_label, &
                            separator_chars, comment_char, continuation_char, quote_char, &
                            section_char, parse_white_lines, initial_variables, apply_preprocessing)
      TYPE(cp_parser_type), INTENT(OUT)                  :: parser
      CHARACTER(LEN=*), INTENT(IN), OPTIONAL             :: file_name
      INTEGER, INTENT(in), OPTIONAL                      :: unit_nr
      TYPE(cp_para_env_type), OPTIONAL, POINTER          :: para_env
      CHARACTER(LEN=*), INTENT(IN), OPTIONAL             :: end_section_label, separator_chars
      CHARACTER(LEN=1), INTENT(IN), OPTIONAL             :: comment_char, continuation_char, &
                                                            quote_char, section_char
      LOGICAL, INTENT(IN), OPTIONAL                      :: parse_white_lines
      CHARACTER(len=*), DIMENSION(:, :), OPTIONAL        :: initial_variables
      LOGICAL, INTENT(IN), OPTIONAL                      :: apply_preprocessing

      parser%input_unit = -1
      parser%input_file_name = ""
      NULLIFY (parser%initial_variables)

      ! Load the default values and overwrite them, if requested
      parser%separators = default_separators
      IF (PRESENT(separator_chars)) parser%separators = separator_chars
      parser%comment_character = default_comment_character
      IF (PRESENT(comment_char)) parser%comment_character = comment_char
      parser%continuation_character = default_continuation_character
      IF (PRESENT(continuation_char)) parser%continuation_character = continuation_char
      parser%quote_character = default_quote_character
      IF (PRESENT(quote_char)) parser%quote_character = quote_char
      parser%section_character = default_section_character
      IF (PRESENT(section_char)) parser%section_character = section_char
      parser%end_section = parser%section_character//default_end_section_label
      IF (PRESENT(end_section_label)) THEN
         parser%end_section = parser%section_character//TRIM(end_section_label)
      END IF
      parser%parse_white_lines = .FALSE.
      IF (PRESENT(parse_white_lines)) THEN
         parser%parse_white_lines = parse_white_lines
      END IF
      parser%apply_preprocessing = .TRUE.
      IF (PRESENT(apply_preprocessing)) THEN
         parser%apply_preprocessing = apply_preprocessing
      END IF

      CALL compress(parser%end_section) ! needed?

      ! para_env
      IF (PRESENT(para_env)) THEN
         parser%para_env => para_env
         CALL cp_para_env_retain(para_env)
      ELSE
         NULLIFY (parser%para_env)
         CALL cp_para_env_create(parser%para_env, group=mp_comm_self, source=0, &
                                 mepos=0, num_pe=1, owns_group=.FALSE.)
      END IF

      !   *** Get the logical output unit number for error messages ***
      IF (parser%para_env%ionode) THEN
         IF (PRESENT(unit_nr)) THEN
            parser%input_unit = unit_nr
            IF (PRESENT(file_name)) parser%input_file_name = file_name
         ELSE
            IF (.NOT. PRESENT(file_name)) &
               CPABORT("at least one of filename and unit_nr must be present")
            CALL open_file(file_name=TRIM(file_name), &
                           unit_number=parser%input_unit)
            parser%input_file_name = file_name
         END IF
      END IF

      IF (PRESENT(initial_variables)) THEN
         IF (SIZE(initial_variables, 2) > 0) THEN
            ALLOCATE (parser%initial_variables(2, SIZE(initial_variables, 2)))
            parser%initial_variables = initial_variables
         END IF
      END IF

      parser%input_line_number = 0
      parser%icol = 0
      parser%icol1 = 0
      parser%icol2 = 0
      parser%first_separator = .TRUE.
      NULLIFY (parser%buffer)
      NULLIFY (parser%status)
      NULLIFY (parser%inpp)
      NULLIFY (parser%ilist)
      CALL create_inpp_type(parser%inpp, parser%initial_variables)
      CALL create_ilist_type(parser%ilist)
      CALL create_buffer_type(parser%buffer)
      CALL create_status_type(parser%status)
   END SUBROUTINE parser_create

! **************************************************************************************************
!> \brief   Resets the parser: rewinding the unit and re-initializing all
!>          parser structures
!> \param parser ...
!> \date    12.2008
!> \author  Teodoro Laino [tlaino]
! **************************************************************************************************
   SUBROUTINE parser_reset(parser)
      TYPE(cp_parser_type), INTENT(INOUT)                :: parser

      ! Rewind units
      IF (parser%input_unit > 0) REWIND (parser%input_unit)
      ! Restore initial settings
      parser%input_line_number = 0
      parser%icol = 0
      parser%icol1 = 0
      parser%icol2 = 0
      parser%first_separator = .TRUE.
      ! Release substructures
      CALL release_inpp_type(parser%inpp)
      CALL release_ilist_type(parser%ilist)
      CALL release_buffer_type(parser%buffer)
      CALL release_status_type(parser%status)
      ! Reallocate substructures
      CALL create_inpp_type(parser%inpp, parser%initial_variables)
      CALL create_ilist_type(parser%ilist)
      CALL create_buffer_type(parser%buffer)
      CALL create_status_type(parser%status)
   END SUBROUTINE parser_reset

END MODULE cp_parser_types
