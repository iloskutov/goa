proc _create_cmake_modules { pkgconfig_dir } {
	global config::var_dir config::abi_dir api_dirs project_dir
	global cmake_module_dir
	global cppflags

	set cmake_module_dir [file join $var_dir cmake Modules]
	if {[file exists $cmake_module_dir]} {
		file delete -force $cmake_module_dir }

	file mkdir $cmake_module_dir

	# copy Find*.cmake files from api directories
	foreach api_dir $api_dirs {
		foreach cmake_file [glob -nocomplain $api_dir/Find*.cmake] {
			file copy $cmake_file $cmake_module_dir }
	}

	# find CMakeLists.txt files
	try {
		set cmake_list_files [exec find [file join $project_dir src] -name CMakeLists.txt]
	} trap CHILDSTATUS { } {
		set cmake_list_files ""
	} on error { msg } { error $msg $::errorInfo }

	# acquire used modules from all CMakeLists.txt
	set used_cmake_modules ""
	foreach cmake_list $cmake_list_files {
		try {
			append used_cmake_modules "[exec grep -E {^\s*find_package\(\w+} $cmake_list | sed -e {s/\s*find_package(\(\w*\).*/\1/}] "
		} trap CHILDSTATUS { } {
		} on error { msg } { error $msg $::errorInfo }
	}

	set pkgconfig_dir_available [file exists $pkgconfig_dir]

	#
	# create missing Find*.cmake files if corresponding api is used
	#
	# Note: We compare the lower-case package name used by cmake with the
	#       archive names mentioned in used_apis. More precisely, the archive
	#       name must end with the lower-case package name. If api archives
	#       provide differently named or multiple packages, they must come with
	#       corresponding Find*.cmake files.
	# 
	foreach package_name $used_cmake_modules {
		set cmake_file [file join $cmake_module_dir Find${package_name}.cmake]
		if {[file exists $cmake_file]} {
			continue }

		# quirk: pthread is provided by our libc
		if {$package_name == "Threads" && [using_api libc]} {
			set fd [open $cmake_file w]
			puts $fd "set(${package_name}_FOUND True)"
			puts $fd "set(CMAKE_USE_PTHREADS_INIT True)"
			puts $fd "if(NOT TARGET Threads::Threads)"
			puts $fd "  add_library(Threads::Threads INTERFACE IMPORTED)"
			puts $fd "endif()"
			close $fd
			continue
		}

		set api_dir [lsearch -inline -nocase -regexp $api_dirs /.*$package_name/\[^/\]+$]
		if {$api_dir != ""} {
			set archive_name [lindex [split $api_dir "/"] end-1]

			diag "CMake module $package_name is provided by used $archive_name api"

			set fd [open $cmake_file w]
			puts $fd "set(${package_name}_FOUND True)"

			#
			# For the moment querying the pkg-config files is solely inteded for
			# incorporating additional include paths - the provided '*_INCLUDE_DIRS'
			# and '*_LIBRARIES' variables might not be evaluated by a project.
			#
			set provides_pc_files [glob -nocomplain $api_dir/*.pc]
			if {$pkgconfig_dir_available && $provides_pc_files != ""} {
				set pc_cflags [query_pkgconfig "$pkgconfig_dir" "$package_name" "--cflags"]
				if {$pc_cflags != ""} {
					# append as cppflags are used by C_FLAGS and CXX_FLAGS
					set cppflags "$cppflags $pc_cflags"

					set cmake_include_dirs { }
					foreach flag $pc_cflags {
						lappend cmake_include_dirs [regsub -all -- {-I} $flag {}] }
					set cmake_include_dirs [join $cmake_include_dirs ";"]
					puts $fd "set(${package_name}_INCLUDE_DIRS \"$cmake_include_dirs\")" }

				set pc_libs [query_pkgconfig "$pkgconfig_dir" "$package_name" "--libs"]
				if {$pc_libs != ""} {
					set cmake_libraries { }
					foreach lib $pc_libs {
						lappend cmake_libraries [regsub -all -- {-l} $lib {}] }

					set cmake_libraries [join $cmake_libraries ";"]
					puts $fd "set(${package_name}_LIBRARIES \"$cmake_libraries\")" }
			}
			close $fd
		} else {
			log "CMake module $package_name is not provided by any api archive" \
			    "please consider adding the corresponding api archive to the used_apis file."

			set fd [open $cmake_file w]
			puts $fd "set(${package_name}_FOUND False)"
			close $fd
		}
	}
	return $cmake_module_dir
}


proc create_or_update_build_dir { } {

	global tool_dir
	global cppflags cflags cxxflags spec_args
	global env cmake_quirk_args
	global config::build_dir project_dir config::abi_dir
	global config::cross_dev_prefix project_name

	set pkgconfig_dir [create_pkgconfig_dir]

	# check whether CMakeLists.txt modifies CMAKE_MODULE_PATH
	set     check_modules_cmd grep
	lappend check_modules_cmd set\(CMAKE_MODULE_PATH
	lappend check_modules_cmd [file join $project_dir src CMakeLists.txt]
	if {[exec_status $check_modules_cmd] == 0} {
		exit_with_error "src/CMakeLists.txt sets CMAKE_MODULE_PATH, which must be" \
		                "\nsolely managed by Goa. Please patch the file accordingly."
	}

	if {![file exists $build_dir]} {
		file mkdir $build_dir }

	# build directory must exist beforehand
	set cmake_module_dir [_create_cmake_modules "$pkgconfig_dir"]

	create_spec_file "" ""

	set orig_pwd [pwd]
	cd $build_dir

	set     cmd [goa::sandboxed_build_command]
	lappend cmd cmake
	lappend cmd "-DCMAKE_IGNORE_PREFIX_PATH='/;/usr'"
	lappend cmd "-DCMAKE_MODULE_PATH='$cmake_module_dir;[file join $tool_dir cmake Modules]'"
	lappend cmd "-DCMAKE_SYSTEM_NAME=Genode"
	lappend cmd "-DCMAKE_C_COMPILER=${cross_dev_prefix}gcc"
	lappend cmd "-DCMAKE_CXX_COMPILER=${cross_dev_prefix}g++"
	lappend cmd "-DCMAKE_C_FLAGS='$spec_args $cflags $cppflags'"
	lappend cmd "-DCMAKE_CXX_FLAGS='$spec_args $cxxflags $cppflags'"
	lappend cmd "-DCMAKE_EXE_LINKER_FLAGS=''"
	lappend cmd "-DCMAKE_SHARED_LINKER_FLAGS='-shared'"
	lappend cmd "-DCMAKE_MODULE_LINKER_FLAGS='-shared'"
	lappend cmd "-DCMAKE_INSTALL_PREFIX:PATH=[file join $build_dir install]"
	lappend cmd "-DCMAKE_SYSTEM_LIBRARY_PATH='$abi_dir'"

	if {[info exists cmake_quirk_args]} {
		foreach arg $cmake_quirk_args {
			lappend cmd $arg } }

	# add project-specific arguments read from 'cmake_args' file
	foreach arg [read_file_content_as_list [file join $project_dir cmake_args]] {
		lappend cmd $arg }

	lappend cmd [file join $project_dir src]

	diag "create build directory via cmake"

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:cmake\] /" >@ stdout} msg]} {
		exit_with_error "build-directory creation via cmake failed:\n" $msg }

	cd $orig_pwd
}


proc build { } {
	global verbose tool_dir
	global config::build_dir config::debug config::jobs project_name

	set     cmd [goa::sandboxed_build_command]
	lappend cmd make -C $build_dir "-j$jobs"

	if {$verbose == 0} {
		lappend cmd "-s"
	} else {
		lappend cmd "VERBOSE=1"
	}

	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:cmake\] /" >@ stdout} msg]} {
		exit_with_error "build via cmake failed:\n" $msg }

	if { $debug == 1 } {
		set install_target "install"
	} else {
		set install_target "install/strip"
	}

	# return if $install_target target does not exist
	if {[exec_status [list {*}$cmd -q $install_target]] == 2} {
		return }

	# at this point, we know that the $install_target exists
	lappend cmd $install_target
	if {[catch {exec -ignorestderr {*}$cmd | sed "s/^/\[$project_name:cmake\] /" >@ stdout} msg]} {
		exit_with_error "install via cmake failed:\n" $msg }
}
