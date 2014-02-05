#!/bin/bash

backup() {
  # $@ are files to be backed up
  for file in $@; do
    mv "$file" "${file}.bkp"
  done
}
inform() {
  echo "[*] $@"
}
warn() {
  echo "[!] $@"
}
homelink() {
  # $1 is the file to link, it will get linked from ~/ to point to the
  # downloaded source_dir
  #ln -s FILE_TO_WHICH_TO_LINK NAME_OF_LINK
  ln -s "${source_dir}/${1}" "${HOME}/$1"
}

# check that we are in the right starting place
# also save the directory for use later
if grep -q BASHRC_COMPLETE "./.bashrc" 2> /dev/null; then
  # then we are probably in the right place
  source_dir=$(pwd)
else
  warn "You don't seem to be running this installer from the downloaded bash directory."
  warn "Try cd'ing to the 'bash' dir inside the downloaded bashrc framework."
  exit 128
fi

home_files_to_backup="${HOME}/.bash_profile ${HOME}/.bashrc ${HOME}/.vimrc"
inform "backing up $home_files_to_backup"
backup home_files_to_backup

# softlink to the framework files.  You should check these files since
# you don't know for sure what code you are getting when you git
# clone/pull
inform "linking your dot files to the framework files"
homelink ".bash_profile"
homelink ".bashrc"
homelink "load_drop_directories.rc"
homelink ".vimrc"
# and directories
for dropdir in $(ls ${source_dir}/*.d); do
  homelink "$dropdir"
done

inform "Creating ${HOME}/private.d, put anything private in there that
you want to get loaded.  See the new *.d directories in ${HOME} for
examples"
mkdir ${HOME}/private.d # for your secret sauce, it will get loaded automatically
# put stuff in private.d, and don't forget to chmod them
inform "Setting perms on private.d to RWX by owner only"
chmod -R 700 ${HOME}/private.d # or whatever
