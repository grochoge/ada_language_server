------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                        Copyright (C) 2022, AdaCore                       --
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
--  Implementation of the command to reload current project.

with Ada.Streams;

with LSP.Client_Message_Receivers;
with LSP.Commands;
with LSP.Errors;
with LSP.JSON_Streams;

package LSP.Ada_Handlers.Project_Reload_Commands is

   type Command is new LSP.Commands.Command with private;

private

   type Command is new LSP.Commands.Command with null record;

   overriding function Create
     (JS : not null access LSP.JSON_Streams.JSON_Stream'Class)
       return Command;

   overriding procedure Execute
     (Self    : Command;
      Handler : not null access
        LSP.Server_Notification_Receivers.Server_Notification_Receiver'Class;
      Client  : not null access
        LSP.Client_Message_Receivers.Client_Message_Receiver'Class;
      Error  : in out LSP.Errors.Optional_ResponseError);

   procedure Write_Command
     (S : access Ada.Streams.Root_Stream_Type'Class;
      V : Command);

   for Command'Write use Write_Command;
   for Command'External_Tag use "als-reload-project";

end LSP.Ada_Handlers.Project_Reload_Commands;
