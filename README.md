gen_process
===========

A behaviour module for implementing a process able to consume messages. A generic process (gen_process) implemented using this module will have a standard set of interface functions and include functionality for tracing and error reporting. It will also fit into an OTP supervision tree. Refer to OTP Design Principles for more information.

Goals
-----

gen_process was created to be a low level behaviour complementing the *gen_server* and *gen_fsm* behaviours provided by OTP.

