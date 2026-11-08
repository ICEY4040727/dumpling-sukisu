### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=SukiSU-Ultra 4.4.302 for OnePlus 5/5T (LineageOS 22.2)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=cheeseburger
device.name2=dumpling
device.name3=OnePlus5
device.name4=OnePlus5T
supported.versions=15
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
# Verified against Seshiria/op5dc anykernel.sh and LineageOS BoardConfigCommon.mk:
#   AB_OTA_UPDATER := false  -> non-slot device
#   BOARD_KERNEL_IMAGE_NAME := Image.gz-dtb
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
## end boot install

# NOTE: SukiSU is compiled built-in (CONFIG_KSU=y), so there are no out-of-tree
# kernel modules to install: do.modules=0 above is intentional.
# NOTE: Unlike the upstream op5dc template, the legacy init.tuna.rc / fstab.tuna
# example edits were removed. They are AnyKernel3 sample code and do not apply
# to msm8998; leaving them in only produces spurious backup_file warnings.
