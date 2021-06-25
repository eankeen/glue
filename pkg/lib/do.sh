# shellcheck shell=bash

doSync() {
	# ------------------------- Nuke ------------------------- #
	log.info "Nuking all files and dirs in '*/auto/'"
	mkdir -p "$GLUE_WD"/.glue/{actions,tasks,util,configs,output}/auto
	find "$GLUE_WD"/.glue/{actions,tasks,commands,common,util,configs,output}/auto/ \
			-ignore_readdir_race -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
		| xargs -r0 -- rm -rf

	# ------------------------- Copy ------------------------- #
	# ROOT
	log.info "Copying all files from '\$GLUE_STORE/root' to './'"
	find "$GLUE_STORE/root/" -ignore_readdir_race -mindepth 1 -maxdepth 1 -type f -print0 \
		| xargs -r0I '{}' -- cp '{}' "$GLUE_WD/.glue/"

	# UTIL
	log.info "Copying all files and dirs from '\$GLUE_STORE/util/' to 'util/'"
	find "$GLUE_STORE/util/" -ignore_readdir_race -mindepth 1 -maxdepth 1 -print0 \
		| xargs -r0I '{}' -- cp -r '{}' "$GLUE_WD/.glue/util/auto/"

	# TASKS
	log.info "Copying all files and dirs from '\$GLUE_STORE/tasks' to 'tasks/'"
	local projectTypeStr
	for projectType in "${GLUE_USING[@]}"; do
		projectTypeStr="${projectTypeStr}${projectType}\|"
	done
	[[ "${#GLUE_USING[@]}" -gt 0 ]] && projectTypeStr="${projectTypeStr:: -2}"
	find "$GLUE_STORE/tasks/" \
			-ignore_readdir_race -mindepth 1 -maxdepth 1 -type f \
			-regextype posix-basic -regex "^.*/\($projectTypeStr\)\..*$" -print0 \
		| xargs -r0I '{}' -- cp '{}' "$GLUE_WD/.glue/tasks/auto/"

	# ACTIONS, CONFIGS
	# <directoryToSearchAnnotations:annotationName:directoryToSearchForFile>
	local arg
	for arg in 'tasks:useAction:actions' 'actions:useAction:actions' 'actions:useConfig:configs'; do
		local searchDir="${arg%%:*}"
		local annotationName="${arg#*:}"; annotationName="${annotationName%:*}"
		local fileDir="${arg##*:}"

		log.info "Copying proper files and dirs from '\$GLUE_STORE/$searchDir to '$fileDir/"

		local -a files=()
		readarray -d $'\0' files < <(find "$GLUE_WD"/.glue/$searchDir/{,auto/} -ignore_readdir_race -type f \
				-exec cat {} \; \
			| sed -Ene "s/^(\s*)?(\/\/|#)(\s*)?glue(\s*)?${annotationName}\((.*?)\)$/\5/p" - \
			| sort -u \
			| tr '\n' '\0'
		)

		# 'file' is a relative path
		for file in "${files[@]}"; do
			if [ -e "$GLUE_STORE/$fileDir/$file" ]; then
				case "$file" in
				*/*)
					# If file contains a directory path in it
					mkdir -p "$GLUE_WD/.glue/$fileDir/auto/${file%/*}"
					cp "$GLUE_STORE/$fileDir/$file" "$GLUE_WD/.glue/$fileDir/auto/${file%/*}"
					;;
				*)
					cp -r "$GLUE_STORE/$fileDir/$file" "$GLUE_WD/.glue/$fileDir/auto/"
				esac
			else
				log.warn "Corresponding file or directory for annotation '$annotationName($file)' not found in directory '$GLUE_STORE/$fileDir'. Skipping"
			fi
		done
	done
}

doList() {
	local -A tasks=()

	shopt -s dotglob
	shopt -s nullglob

	local filePath
	for filePath in "$GLUE_WD"/.glue/tasks/* "$GLUE_WD"/.glue/tasks/auto/*; do
		local file="${filePath##*/}"
		local task="${file%%.*}"

		# Do not include files without a projectType
		if [ "$file" = "$task" ]; then
			continue
		fi

		tasks+=(["$task"]='')
	done

	for task in "${!tasks[@]}"; do
		echo "$task"
	done
}

doPrint() {
	[[ -z $1 ]] && die 'No action file passed'

	# TODO: code duplication
	helper.get_executable_file "$GLUE_WD/.glue/actions/$1"
	local overrideFile="$REPLY"

	helper.get_executable_file "$GLUE_WD/.glue/actions/auto/$1"
	local autoFile="$REPLY"

	hasRan=no
	if [ -f "$overrideFile" ]; then
		helper.exec_file "$overrideFile" "no"
		hasRan=yes
	elif [ -f "$autoFile" ]; then
		helper.exec_file "$autoFile" "yes"
		hasRan=yes
	fi

	if [[ $hasRan == no ]]; then
		log.error "Action file '$1' did match any files"
		echo "    -> Is the task contained in '.glue/actions/auto' or '.glue/actions'?" >&2
		exit 1
	fi
}

# TODO: pass option whether to explicitly use 'auto' or non-auto file
doAct() {
	local actionFile="${argsCommands[1]}"

	[[ -z $actionFile ]] && die 'No action file passed'
	# -------------- Store Init (*.boostrap.sh) -------------- #
	helper.get_executable_file "$GLUE_STORE/bootstrap"
	local bootstrapFile="$REPLY"
	GLUE_BOOTSTRAP=$(<"$bootstrapFile") || die "Could not get contents of bootstrap file '$bootstrapFile'"


	helper.get_executable_file "$GLUE_WD/.glue/actions/$actionFile"
	local overrideFile="$REPLY"

	helper.get_executable_file "$GLUE_WD/.glue/actions/auto/$actionFile"
	local autoFile="$REPLY"

	hasRan=no
	if [ -f "$overrideFile" ]; then
		helper.exec_file "$overrideFile" "no"
		hasRan=yes
	elif [ -f "$autoFile" ]; then
		helper.exec_file "$autoFile" "yes"
		hasRan=yes
	fi

	if [[ $hasRan == no ]]; then
		log.error "Action file '$actionFile' did match any files"
		echo "    -> Is the task contained in '.glue/actions/auto' or '.glue/actions'?" >&2
		exit 1
	fi
}

doCmd() {
	local metaTask="${argsCommands[1]}"
	[[ -z $metaTask ]] && die 'No meta task passed'

	# -------------- Store Init (*.boostrap.sh) -------------- #
	helper.get_executable_file "$GLUE_STORE/bootstrap"
	local bootstrapFile="$REPLY"
	GLUE_BOOTSTRAP=$(<"$bootstrapFile") || die "Could not get contents of bootstrap file '$bootstrapFile'"

	# -------------------- Parse Meta task ------------------- #
	get.task "$metaTask"
	local task="$REPLY"

	get.projectType "$metaTask"
	local projectType="$REPLY"

	get.when "$metaTask"
	local when="$REPLY"

	# --------------------- Sanity check --------------------- #
	if [ -z "$task" ]; then
		die "Specifying a 'task is required"
	fi

	if [[ -v DEBUG ]]; then
		echo "task: $task"
		echo "projectType: $projectType"
		echo "when: $when"
	fi

	# calculate 'projectType's to run
	local -a projectTypes=()
	if [[ -v GLUE_USING ]]; then
		projectTypes=("" "${GLUE_USING[@]}")
	else
		die "Must set the 'using' variable in the Glue project configuration (glue.toml)"
	fi

	# calculate 'when's to run
	local -a whens=()
	if [ -n "$when" ]; then
		# a blank 'when' represents a file like 'build-go.sh' compared to 'build-go-before.sh'
		case "$when" in
			before) whens=("-before") ;;
			only) whens=("") ;;
			after) whens=("-after") ;;
			*) die "When '$when' not valid. Must be of either 'before', 'only', or 'after'"
		esac
	else
		whens=("-before" "" "-after")
	fi

	# run and execute files in order
	local hasRan=no
	for projectType in "${projectTypes[@]}"; do
		for when in "${whens[@]}"; do
			helper.get_executable_file "$GLUE_WD/.glue/tasks/${projectType}.${task}${when}"
			local overrideFile="$REPLY"

			helper.get_executable_file "$GLUE_WD/.glue/tasks/auto/${projectType}.${task}${when}"
			local autoFile="$REPLY"

			if [ -f "$overrideFile" ]; then
				helper.exec_file "$overrideFile" "no" "${argsPostHyphen[@]}"
				hasRan=yes
			elif [ -f "$autoFile" ]; then
				helper.exec_file "$autoFile" "yes" "${argsPostHyphen[@]}"
				hasRan=yes
			fi
		done

	done

	if [[ $hasRan == no ]]; then
		log.error "Task '$task' did match any files"
		echo "    -> Is the task contained in '.glue/tasks/auto' or '.glue/tasks'?" >&2
		echo "    -> Was a task like 'build', 'ci', etc. actually specified?" >&2
		exit 1
	fi
}
