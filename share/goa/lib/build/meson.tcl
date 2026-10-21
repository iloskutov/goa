#
# Meson specific implementation
#

proc _mangle_pkgconfig_files { } {
	global config::build_dir project_name

	set meson_pc_file_dir "[file join $build_dir meson-private]"

	foreach pc_file [glob -nocomplain $meson_pc_file_dir/*.pc] {

		# first replace $prefix with placeholder to have a useful 'Cflags' field
		set     cmd [sandboxed_build_command]
		lappend cmd "sed -i 's;prefix=.*$;prefix=DEPOT_API_DIR;' $pc_file"
		if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:meson\] /" >@ stdout} msg]} {
			exit_with_error "mangeling pkgconfig file '[file tail $pc_file]' via meson failed:\n" $msg }

		# second parse 'Libs:' field and replace every linker directive to generate
		# a useful 'Libs:' field
		set     cmd [sandboxed_build_command]
		lappend cmd "grep '^Libs:' $pc_file"
		set success 0
		if {[catch {exec -ignorestderr {*}$cmd} msg] == 0} {
			set success 1
		}
		# not all .pc files contain an Libs field
		if {$success != 1} { return }

		set libs_line [lindex [split $msg "\n"] end]
		set mangeled_libs { }
		foreach lib_flag $libs_line {
			if {[string equal -length 2 "-l" $lib_flag] == 1} {
				set lib [regsub -all -- {-l} $lib_flag {}]

				# verbatim lib flags denoted already mangled ones,
				# e.g. -l:pcsc-lite.lib.so, copy them directly
				if {[string equal -length 1 ":" $lib] == 1} {
					lappend mangeled_libs "-l$lib"
				} else {
					lappend mangeled_libs "-l:lib$lib.lib.so"
				}
			}
		}

		if {[llength $mangeled_libs] != 0} {
			set libs_line "Libs: $mangeled_libs"

			set     cmd [sandboxed_build_command]
			lappend cmd "sed -i 's;Libs:.*$;$libs_line;' $pc_file"
			if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:meson\] /" >@ stdout} msg]} {
				exit_with_error "mangeling pkgconfig file '[file tail $pc_file]' via meson failed:\n" $msg }
		}

		# last remove any '*.private:' field as static libraries should not shine
		# through and used_apis should hopefully cover all external dependencies
		set     cmd [sandboxed_build_command]
		lappend cmd "sed -i 's;^.*\\.private:.*$;;' $pc_file"
		if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:meson\] /" >@ stdout} msg]} {
			exit_with_error "mangeling pkgconfig file '[file tail $pc_file]' via meson failed:\n" $msg }
	}
}


proc create_cross_file { dir pkgconfig_dir } {
	global tool_dir
	global config::arch config::cross_dev_prefix

	set target_machine x86_64
	if {$arch == "arm_v8a"} { set target_machine aarch64 }

	set cross_file [file join $dir meson-cross-genode]

	set fh [open $cross_file "WRONLY CREAT TRUNC"]
	puts $fh "# Genode tool chain for cross compilation (--cross-file)"
	puts $fh "# Automatically generated file."
	puts $fh ""
	puts $fh "\[binaries\]"
	puts $fh "c      = '${cross_dev_prefix}gcc'"
	puts $fh "cpp    = '${cross_dev_prefix}g++'"
	puts $fh "ar     = '${cross_dev_prefix}ar'"
	puts $fh "strip  = '${cross_dev_prefix}strip'"

	#
	# Custom pkg-config command that checks if required libraries are present in
	# abi_dir
	#
	puts $fh "pkg-config = 'pkg-config'"

	puts $fh ""
	puts $fh "\[properties\]"
	puts $fh "needs_exec_wrapper = false"
	puts $fh "pkg_config_libdir  = '$pkgconfig_dir'"
	puts $fh ""
	puts $fh "\[host_machine\]"
	puts $fh "system     = 'freebsd'"
	puts $fh "cpu_family = 'x86_64'"
	puts $fh "cpu        = 'x86_64'"
	puts $fh "endian     = 'little'"
	puts $fh ""
	puts $fh "\[target_machine\]"
	puts $fh "system     = 'freebsd'"
	puts $fh "cpu_family = '$target_machine'"
	puts $fh "cpu        = '$target_machine'"
	puts $fh "endian     = 'little'"
	puts $fh ""
	close $fh

	return $cross_file
}


proc retrieve_rpath_link { } {
	global project_dir

	set rpath_link { }
	foreach arg [read_file_content_as_list [file join $project_dir rpath_link]] {

		# escape $ at beginning of line with \ (e.g., for $ORIGIN)
		if {[regexp {^\$} $arg]} { regsub {^\$} $arg "\\$" arg }
		lappend rpath_link $arg
	}

	return $rpath_link
}


proc create_or_update_build_dir { } {
	global cppflags cflags cxxflags
	global spec_args
	global config::build_dir project_dir config::abi_dir project_name
	global config::cross_dev_prefix config::cc_cxx_opt_std config::debug
	global pkgconfig_dir

	if {![file exists $build_dir]} {
		file mkdir $build_dir }

	# create/empty pkg-config.log
	set pkg_config_log [file join $build_dir "pkg-config.log"]
	set fh [open $pkg_config_log "WRONLY CREAT TRUNC"]
	close $fh

	# create link to abi to be processed by 'pkg-config.tcl'
	set link_abi [file join $build_dir abi]
	if {[expr ![file exists $link_abi]]} {
		file link -symbolic $link_abi $abi_dir
	}

	set source_dir [file join $project_dir src]

	set     cmd [sandboxed_build_command]
	lappend cmd --tmp-overlay $source_dir
	lappend cmd meson
	lappend cmd "setup"

	# installation prefix
	lappend cmd "-Dprefix=[file join $build_dir install]"


	#
	# Options
	#

	# if debug -> enable assertion
	set b_ndebug  "true"
	if { $debug == 1 } {
		set b_ndebug "false"
	} else {
		lappend cmd "--strip"
	}
	lappend cmd "-Db_ndebug=$b_ndebug"

	#
	# Disable the -Wl,--as-needed ld flag, we always want all shared libaries to
	# appear in DT_NEEDED in the ELF file
	#
	lappend cmd "-Db_asneeded=false"


	#
	# c/c++ args
	#
	lappend cmd "-Dc_args=$cflags $cppflags"
	lappend cmd "-Dcpp_args=$cxxflags $cppflags"
	lappend cmd "-Dcpp_std=[lindex [split $cc_cxx_opt_std =/] 1]"

	set rpath_link [retrieve_rpath_link]
	set link_args ""
	if {[llength $rpath_link] > 0} {
		set link_args -rpath-link=[join $rpath_link :]
	}

	create_spec_file $link_args $link_args

	#
	# Used for feature testing compiles
	#
	lappend cmd "-Dc_link_args=$spec_args"
	lappend cmd "-Dcpp_link_args=$spec_args"


	# add project-specific arguments read from 'meson_args' file
	foreach arg [read_file_content_as_list [file join $project_dir meson_args]] {
		lappend cmd $arg }

	lappend cmd "--cross-file"
	lappend cmd [create_cross_file $build_dir $pkgconfig_dir]
	lappend cmd "--reconfigure"
	lappend cmd $build_dir
	lappend cmd $source_dir

	diag "create build directory via meson"

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:meson\] /" >@ stdout} msg]} {
		exit_with_error "build-directory creation via meson failed:\n" $msg }
}


proc build { } {
	global verbose
	global config::build_dir project_name
	global config::jobs
	global spec_args

	diag "build:"
	set     cmd [sandboxed_build_command]
	lappend cmd meson compile -C $build_dir -j $jobs

	if {$verbose} { lappend cmd "--verbose" }

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:meson\] /" >@ stdout} msg]} {
		exit_with_error "build via meson failed:\n" $msg }

	_mangle_pkgconfig_files

	# install
	set     cmd [sandboxed_build_command]
	lappend cmd meson install --no-rebuild -C $build_dir
	if { $verbose == 0} {
		lappend cmd "--quiet"
	}

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:meson\] /" >@ stdout} msg]} {
		exit_with_error "install via meson failed:\n" $msg }
}
