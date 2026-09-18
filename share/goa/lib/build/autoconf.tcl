proc _configure_cmd { } {
	global cppflags cflags cxxflags api_dirs spec_args
	global config::arch config::build_dir config::cross_dev_prefix
	global project_dir

	create_spec_file "" ""

	set pkgconfig_dir [create_pkgconfig_dir]

	set     cmd [goa::sandboxed_build_command]

	set host x86_64-pc-elf
	if {$arch == "arm_v8a"} { set host aarch64-elf }

	lappend cmd "./configure"
	lappend cmd "--prefix" "/"
	lappend cmd "--host" $host
	lappend cmd "CPPFLAGS=$cppflags"
	lappend cmd "CFLAGS=$cflags"
	lappend cmd "CXXFLAGS=$cxxflags"
	lappend cmd "CXX=${cross_dev_prefix}g++ $spec_args"
	lappend cmd "CC=${cross_dev_prefix}gcc $spec_args"
	lappend cmd "STRIP=${cross_dev_prefix}strip"
	lappend cmd "RANLIB=${cross_dev_prefix}ranlib"
	lappend cmd "AR=${cross_dev_prefix}ar"
	lappend cmd "AS=${cross_dev_prefix}as"
	lappend cmd "PKG_CONFIG_LIBDIR=''"
	lappend cmd "PKG_CONFIG_PATH='$pkgconfig_dir'"

	# keep LDLIBS_SHARED for backward compatibility (-shared is replaced by specs)
	lappend cmd "LDLIBS_SHARED=-shared"

	#
	# Some autoconf projects (e.g. OpenSC) unconditionally do checks
	# on the C/C++ preprocessors and therefore need these variables.
	#
	lappend cmd "CPP=${cross_dev_prefix}cpp"
	lappend cmd "CXXCPP=${cross_dev_prefix}cpp"

	# add project-specific arguments read from 'configure_args' file
	foreach arg [read_file_content_as_list [file join $project_dir configure_args]] {
		lappend cmd $arg }

	return $cmd
}


proc create_or_update_build_dir { } {
	global config::build_dir project_name project_dir spec_file

	# compare configure command and link spec, and clear directory if anything changed
	set signature_file [file join $build_dir ".goa_configure_command"]

	set previous_cmd       [string trim [read_file_content $signature_file]]
	set previous_link_spec [string trim [read_file_content $spec_file]]

	set cmd       [join [_configure_cmd] { }]
	set link_spec [string trim [read_file_content $spec_file]]

	if {"$previous_cmd" != "$cmd" || "$previous_link_spec" != "$link_spec"} {
		file delete -force $build_dir
	}

	mirror_source_dir_to_build_dir

	# write build command to file
	set fd [open $signature_file w]
	puts $fd $cmd
	close $fd

	# invoke configure script only once
	if {[file exists [file join $build_dir config.status]]} {
		return }

	set orig_pwd [pwd]

	#
	# If the configure script doesn't exist yet, it has to be
	# generated first via the configure.ac file using autoreconf.
	#
	if {[expr ![file exists [file join src configure]]]} {

		set     cmd [goa::sandboxed_build_command]
		lappend cmd "autoreconf"
		lappend cmd "--install"

		diag "create build system via autoreconf"

		cd $build_dir
		if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:autoconf\] /" >@ stdout} msg]} {
			exit_with_error "build-system creation via autoconf failed:\n" $msg
		}
		cd $orig_pwd
	}


	diag "create build directory via autoconf"

	set cmd [_configure_cmd]

	cd $build_dir

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:autoconf\] /" >@ stdout} msg]} {
		exit_with_error "build-directory creation via autoconf failed:\n" $msg }

	cd $orig_pwd
}


proc build { } {

	global verbose
	global config::build_dir project_name config::jobs project_dir

	set     cmd [goa::sandboxed_build_command]

	# pass variables that are not fully handled by configure scripts
	lappend cmd make -C $build_dir
	lappend cmd "DESTDIR=[file join $build_dir install]"
	lappend cmd "-j$jobs"

	#
	# Autoconf adds consideration of the variable 'V' to generated Makefiles
	# in order to control make verbosity. There are only two values: '0'
	# means less verbosity and '1' more verbosity.
	#
	if {$verbose == 1} {
		lappend cmd "V=1"
	} else {
		lappend cmd "-s"
		lappend cmd "V=0"
	}

	# add project-specific arguments read from 'make_args' file
	foreach arg [read_file_content_as_list [file join $project_dir make_args]] {
		lappend cmd $arg }

	# skip make (and make install) if there is nothing to be made
	if {[exec_status [list {*}$cmd -q]] == 0} {
		diag "everything is up to date"
		return
	}

	diag "build via make"

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:make\] /" >@ stdout}]} {
		exit_with_error "build via make failed" }

	# return if 'install' target does not exist
	if {[exec_status [list {*}$cmd -q install]] == 2} {
		return }

	# at this point, we know that the 'install' target exists
	lappend cmd install
	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:make\] /" >@ stdout}]} {
		exit_with_error "install via make failed" }
}
