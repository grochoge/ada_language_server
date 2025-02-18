------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                     Copyright (C) 2018-2023, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------
--
--  This is driver to run LSP server for Ada language.

with Ada.Characters.Latin_1;
with Ada.Text_IO;
with Ada.Exceptions;          use Ada.Exceptions;
with Ada.Strings.Unbounded;
with GNAT.Traceback.Symbolic; use GNAT.Traceback.Symbolic;
with GNAT.OS_Lib;
with GNAT.Strings;

pragma Warnings (Off, "is an internal GNAT unit");
with System.Soft_Links;
with System.Secondary_Stack;

with VSS.Application;
with VSS.Command_Line;
with VSS.Standard_Paths;
with VSS.Strings.Conversions;
with VSS.Text_Streams.Standards;

with GNATCOLL.JSON;
with GNATCOLL.Memory;         use GNATCOLL.Memory;
with GNATCOLL.Traces;         use GNATCOLL.Traces;
with GNATCOLL.VFS;            use GNATCOLL.VFS;
with GNATCOLL.Utils;

with LSP.Ada_Handlers;
with LSP.Ada_Handlers.Named_Parameters_Commands;
with LSP.Ada_Handlers.Other_File_Commands;
with LSP.Ada_Handlers.Project_Reload_Commands;
with LSP.Ada_Handlers.Refactor_Imports_Commands;
with LSP.Ada_Handlers.Refactor_Add_Parameter;
with LSP.Ada_Handlers.Refactor_Remove_Parameter;
with LSP.Ada_Handlers.Refactor_Move_Parameter;
with LSP.Ada_Handlers.Refactor_Change_Parameter_Mode;
with LSP.Ada_Handlers.Refactor_Change_Parameters_Type;
with LSP.Ada_Handlers.Refactor_Change_Parameters_Default_Value;
with LSP.Ada_Handlers.Refactor_Suppress_Seperate;
with LSP.Ada_Handlers.Refactor_Extract_Subprogram;
with LSP.Ada_Handlers.Refactor_Introduce_Parameter;
with LSP.Ada_Handlers.Refactor_Pull_Up_Declaration;
with LSP.Ada_Handlers.Refactor_Replace_Type;
with LSP.Ada_Handlers.Refactor_Sort_Dependencies;
with LSP.Commands;
with LSP.Error_Decorators;
with LSP.Fuzz_Decorators;
with LSP.GPR_Handlers;
with LSP.Memory_Statistics;
with LSP.Predefined_Completion;
with LSP.Servers;
with LSP.Stdio_Streams;

--------------------
-- LSP.Ada_Driver --
--------------------

procedure LSP.Ada_Driver is

   procedure On_Uncaught_Exception (E : Exception_Occurrence);
   --  Reset LAL contexts in Message_Handler after catching some exception.

   procedure Register_Commands;
   --  Register all known commands

   procedure Die_On_Uncaught (E : Exception_Occurrence);
   --  Quit the process when an uncaught exception reaches this. Used for
   --  fuzzing.

   procedure Print_Help (Option : VSS.Command_Line.Named_Option'Class);
   --  Put option description to stdout

   Server_Trace : constant Trace_Handle := Create ("ALS.MAIN", From_Config);
   --  Main trace for the LSP.

   In_Trace  : constant Trace_Handle := Create ("ALS.IN", Off);
   Out_Trace : constant Trace_Handle := Create ("ALS.OUT", Off);
   --  Traces that logs all input & output. For debugging purposes.

   Server      : aliased LSP.Servers.Server;
   Stream      : aliased LSP.Stdio_Streams.Stdio_Stream;
   Ada_Handler : aliased LSP.Ada_Handlers.Message_Handler
     (Server'Access, Server_Trace);
   GPR_Handler : aliased LSP.GPR_Handlers.Message_Handler;

   Error_Decorator : aliased LSP.Error_Decorators.Error_Decorator
     (Server_Trace,
      Ada_Handler'Unchecked_Access,
      On_Uncaught_Exception'Unrestricted_Access);
   --  This decorator catches all Property_Error exceptions and provides
   --  default responses for each request. It also reset Libadalang Context
   --  on any other exception.

   ---------------------------
   -- On_Uncaught_Exception --
   ---------------------------

   procedure On_Uncaught_Exception (E : Exception_Occurrence) is
   begin
      Trace (Server_Trace,
             "EXCEPTION: " & Exception_Name (E) &
               Ada.Characters.Latin_1.LF &
               "INFORMATION: " & Exception_Information (E) &
               Ada.Characters.Latin_1.LF &
               Symbolic_Traceback (E));
      Ada_Handler.Handle_Error;
   end On_Uncaught_Exception;

   ---------------------
   -- Die_On_Uncaught --
   ---------------------

   procedure Die_On_Uncaught (E : Exception_Occurrence) is
   begin
      Trace (Server_Trace,
             "EXCEPTION: " & Exception_Name (E) &
               Ada.Characters.Latin_1.LF &
               "INFORMATION: " & Exception_Information (E) &
               Ada.Characters.Latin_1.LF &
               Symbolic_Traceback (E));
      --  An exception occurred while fuzzing: make it fatal.
      GNAT.OS_Lib.OS_Exit (42);
   end Die_On_Uncaught;

   ----------------
   -- Print_Help --
   ----------------

   procedure Print_Help (Option : VSS.Command_Line.Named_Option'Class) is
      use type VSS.Strings.Character_Count;
      Ok     : Boolean := True;
      Output : VSS.Text_Streams.Output_Text_Stream'Class :=
        VSS.Text_Streams.Standards.Standard_Output;
      Last   : VSS.Strings.Character_Count :=
        3 + Option.Long_Name.Character_Length;
   begin
      Output.Put (" --", Ok);
      Output.Put (Option.Long_Name, Ok);
      if Option in VSS.Command_Line.Value_Option'Class then
         Output.Put ("=ARG", Ok);
         Last := Last + 4;
      end if;

      for J in Last + 1 .. 17 loop
         Output.Put (' ', Ok);
      end loop;
      Output.Put_Line (Option.Description, Ok);
   end Print_Help;

   -----------------------
   -- Register_Commands --
   -----------------------

   procedure Register_Commands is
   begin
      LSP.Commands.Register
        (LSP.Ada_Handlers.Other_File_Commands.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Project_Reload_Commands.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Named_Parameters_Commands.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Imports_Commands.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Suppress_Seperate.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Extract_Subprogram.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Introduce_Parameter.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Pull_Up_Declaration.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Replace_Type.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Sort_Dependencies.Command'Tag);

      --  Refactoring - Change Subprogram Signature Commands
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Add_Parameter.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Remove_Parameter.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Move_Parameter.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Change_Parameter_Mode.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Change_Parameters_Type.Command'Tag);
      LSP.Commands.Register
        (LSP.Ada_Handlers.Refactor_Change_Parameters_Default_Value.
           Command'Tag);
   end Register_Commands;

   use type VSS.Strings.Virtual_String;

   Fuzzing_Activated      : constant Boolean :=
     not VSS.Application.System_Environment.Value ("ALS_FUZZING").Is_Empty;

   ALS_Home               : constant VSS.Strings.Virtual_String :=
     VSS.Application.System_Environment.Value ("ALS_HOME");
   GPR_Path               : constant VSS.Strings.Virtual_String :=
     VSS.Application.System_Environment.Value ("GPR_PROJECT_PATH");
   Path                   : constant VSS.Strings.Virtual_String :=
     VSS.Application.System_Environment.Value ("PATH");
   Home_Dir               : constant Virtual_File :=
     Create_From_UTF8
       (VSS.Strings.Conversions.To_UTF_8_String
          ((if ALS_Home.Is_Empty
              then VSS.Standard_Paths.Writable_Location
                     (VSS.Standard_Paths.Home_Location)
              else ALS_Home)));
   ALS_Dir                : constant Virtual_File := Home_Dir / ".als";
   Clean_ALS_Dir          : Boolean := False;
   GNATdebug              : constant Virtual_File := Create_From_Base
     (".gnatdebug");

   Trace_File_Option      : constant VSS.Command_Line.Value_Option :=
     (Short_Name  => "",
      Long_Name   => "tracefile",
      Description => "Full path to a file containing traces configuration",
      Value_Name  => "ARG");

   Config_Description     : constant VSS.Strings.Virtual_String :=
     "Full path to a JSON file containing initialization "
     & "options for the server (i.e: all the settings that can be specified "
     & "through LSP 'initialize' request's initializattionOptions)";

   Config_File_Option     : constant VSS.Command_Line.Value_Option :=
     (Short_Name  => "",
      Long_Name   => "config",
      Description => Config_Description,
      Value_Name  => "ARG");

   Language_GPR_Option    : constant VSS.Command_Line.Binary_Option :=
     (Short_Name  => "",
      Long_Name   => "language-gpr",
      Description => "Handle GPR language instead of Ada");

   Version_Option         : constant VSS.Command_Line.Binary_Option :=
     (Short_Name  => "",
      Long_Name   => "version",
      Description => "Display the program version");

   Help_Option            : constant VSS.Command_Line.Binary_Option :=
     (Short_Name  => "",
      Long_Name   => "help",
      Description => "Display this help");

   Config_File            : Virtual_File;

   Memory_Monitor_Enabled : Boolean;
begin
   --  Handle the command line
      --  Help => "Command line interface for the Ada Language Server");

   VSS.Command_Line.Add_Option (Trace_File_Option);
   VSS.Command_Line.Add_Option (Config_File_Option);
   VSS.Command_Line.Add_Option (Language_GPR_Option);
   VSS.Command_Line.Add_Option (Version_Option);
   VSS.Command_Line.Add_Option (Help_Option);
   VSS.Command_Line.Process;  --  Will exit if errors

   if VSS.Command_Line.Is_Specified (Help_Option) then
      Ada.Text_IO.Put_Line
        ("Language Server Ada and SPARK.");
      --  TBD: Print list of options using VSS
      Ada.Text_IO.Put_Line
        ("Usage: ada_language_server [switches] [arguments]");
      Ada.Text_IO.New_Line;

      Print_Help (Trace_File_Option);
      Print_Help (Config_File_Option);
      Print_Help (Language_GPR_Option);
      Print_Help (Version_Option);
      Print_Help (Help_Option);

      GNAT.OS_Lib.OS_Exit (0);
   elsif VSS.Command_Line.Is_Specified (Version_Option) then
      Ada.Text_IO.Put_Line ("ALS version: " & $VERSION);
      GNAT.OS_Lib.OS_Exit (0);
   end if;

   --  Look for a traces file, in this order:
   --     - passed on the command line via --tracefile,
   --     - in a .gnatdebug file locally
   --     - in "traces.cfg" in the ALS home directory
   if VSS.Command_Line.Is_Specified (Trace_File_Option) then
      declare
         Traces_File : constant Virtual_File := Create_From_UTF8
           (VSS.Strings.Conversions.To_UTF_8_String
              (VSS.Command_Line.Value (Trace_File_Option)));
      begin
         if not Traces_File.Is_Regular_File then
            Ada.Text_IO.Put_Line ("Could not find the specified traces file");
            GNAT.OS_Lib.OS_Exit (1);
         end if;

         Parse_Config_File (Traces_File);
      end;
   elsif GNATdebug.Is_Regular_File then
      Parse_Config_File (GNATdebug);

   elsif ALS_Dir.Is_Directory then
      Clean_ALS_Dir := True;

      --  Search for custom traces config in traces.cfg
      Parse_Config_File (+Virtual_File'(ALS_Dir / "traces.cfg").Full_Name);

      --  Set log file
      Set_Default_Stream
        (">" & (+Virtual_File'(ALS_Dir / "als").Full_Name) &
           ".$T.$$.log:buffer_size=0");
   end if;

   --  Look for a config file, that contains the configuration for the server
   --  (i.e: the configuration that can be specified through the 'initialize'
   --  request initializationOptions).

   if VSS.Command_Line.Is_Specified (Config_File_Option) then
      Config_File := Create_From_UTF8
        (VSS.Strings.Conversions.To_UTF_8_String
           (VSS.Command_Line.Value (Config_File_Option)));
      if not Config_File.Is_Regular_File then
         Ada.Text_IO.Put_Line ("Could not find the specified config file");
         GNAT.OS_Lib.OS_Exit (1);
      end if;

      declare
         JSON_Contents : GNAT.Strings.String_Access := Config_File.Read_File;
         Parse_Result  : GNATCOLL.JSON.Read_Result;
      begin
         Parse_Result := GNATCOLL.JSON.Read (JSON_Contents.all);
         GNAT.Strings.Free (JSON_Contents);

         if not Parse_Result.Success then
            Ada.Text_IO.Put_Line
              ("Error when parsing config file at "
               & GNATCOLL.Utils.Image (Parse_Result.Error.Line, 1)
               & ":"
               & GNATCOLL.Utils.Image (Parse_Result.Error.Column, 1));
            Ada.Text_IO.Put_Line
              (Ada.Strings.Unbounded.To_String (Parse_Result.Error.Message));
            GNAT.OS_Lib.OS_Exit (1);
         end if;

         Ada_Handler.Change_Configuration (Parse_Result.Value);
      end;
   end if;

   Server_Trace.Trace ("ALS version: " & $VERSION);

   Server_Trace.Trace ("Initializing server ...");

   Server_Trace.Trace
     ("GPR PATH: " & VSS.Strings.Conversions.To_UTF_8_String (GPR_Path));
   Server_Trace.Trace
     ("PATH: " & VSS.Strings.Conversions.To_UTF_8_String (Path));
   --  Start monitoring the memory if the memory monitor trace is active

   Memory_Monitor_Enabled := Create ("DEBUG.ADA_MEMORY").Is_Active;

   if Memory_Monitor_Enabled then
      GNATCOLL.Memory.Configure (Activate_Monitor => True);
   end if;

   if not VSS.Command_Line.Is_Specified (Language_GPR_Option) then
      --  Load predefined completion items
      LSP.Predefined_Completion.Load_Predefined_Completion_Db (Server_Trace);
      Register_Commands;
   end if;

   Server.Initialize (Stream'Unchecked_Access);

   begin
      if VSS.Command_Line.Is_Specified (Language_GPR_Option) then
         Server.Run
           (GPR_Handler'Unchecked_Access,
            GPR_Handler'Unchecked_Access,
            Server       => null,
            On_Error     => On_Uncaught_Exception'Unrestricted_Access,
            Server_Trace => Server_Trace,
            In_Trace     => In_Trace,
            Out_Trace    => Out_Trace);
      elsif Fuzzing_Activated then
         --  Fuzzing mode means registering the fuzzing decorators and
         --  registering Die_On_Uncaught as error handler.
         declare
            Fuzz_Requests : aliased LSP.Fuzz_Decorators.Fuzz_Request_Decorator
              (Server_Trace,
               Error_Decorator'Unchecked_Access,
               Die_On_Uncaught'Unrestricted_Access);
            Fuzz_Notifications : aliased
              LSP.Fuzz_Decorators.Fuzz_Notification_Decorator
                (Server_Trace,
                 Ada_Handler'Unchecked_Access,
                 Ada_Handler'Unchecked_Access);
         begin
            Server.Run
              (Fuzz_Requests'Unchecked_Access,
               Fuzz_Notifications'Unchecked_Access,
               Server       => Ada_Handler'Unchecked_Access,
               On_Error     => Die_On_Uncaught'Unrestricted_Access,
               Server_Trace => Server_Trace,
               In_Trace     => In_Trace,
               Out_Trace    => Out_Trace);
         end;
      else
         Server.Run
           (Error_Decorator'Unchecked_Access,
            Ada_Handler'Unchecked_Access,
            Server       => Ada_Handler'Unchecked_Access,
            On_Error     => On_Uncaught_Exception'Unrestricted_Access,
            Server_Trace => Server_Trace,
            In_Trace     => In_Trace,
            Out_Trace    => Out_Trace);
      end if;
   exception
      when E : others =>
         Server_Trace.Trace
           ("FATAL - Unexpected exception in the main thread: "
            & Exception_Name (E) & " - " &  Exception_Message (E));
         Server_Trace.Trace (Symbolic_Traceback (E));
   end;

   Server_Trace.Trace ("Shutting server down ...");

   --  Dump the memory statistics if the memory monitor trace is active
   if Memory_Monitor_Enabled then
      declare
         Memory_Stats : constant String :=
                          LSP.Memory_Statistics.Dump_Memory_Statistics (3);

      begin
         Server_Trace.Trace (Memory_Stats);
      end;
   end if;

   Ada_Handler.Stop_File_Monitoring;
   Server.Finalize;
   if Clean_ALS_Dir then
      Ada_Handler.Clean_Logs (ALS_Dir);
   end if;
   Ada_Handler.Cleanup;

   --  Clean secondary stack up
   declare
      Stack : System.Secondary_Stack.SS_Stack_Ptr :=
        System.Soft_Links.Get_Sec_Stack.all;
   begin
      System.Secondary_Stack.SS_Free (Stack);
      System.Soft_Links.Set_Sec_Stack (Stack);
   end;
end LSP.Ada_Driver;
