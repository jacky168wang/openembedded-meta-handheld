require recipes-kernel/linux/linux-handheld_${PV}.bb
FILESEXTRAPATHS_prepend := "${THISDIR}/${PN}-${PV}:${THISDIR}/linux-handheld-${PV}:"

SUMMARY = "Linux kernel embedding a minimalistic kexecboot initramfs"

COMPATIBLE_MACHINE = "|akita|c7x0|collie|poodle|spitz|tosa"

LOCOMO_PATCHES += "file://locomo/0091-locomokbd.c-invert-KEY_ENTER-and-KEY_KPENTER.patch"

# only for SL-C3200 (terrier)
# SRC_URI_append_spitz += "file://3200-mtd.patch"

# Zaurus machines need kernel size-check.
KERNEL_IMAGE_MAXSIZE_akita = "1264"
KERNEL_IMAGE_MAXSIZE_c7x0 = "1264"
KERNEL_IMAGE_MAXSIZE_collie = "1024"
KERNEL_IMAGE_MAXSIZE_poodle = "1264"
KERNEL_IMAGE_MAXSIZE_spitz = "1264"
KERNEL_IMAGE_MAXSIZE_tosa = "1264"

PACKAGES = ""
PROVIDES = ""

KERNEL_IMAGE_BASE_NAME = "kexecboot-${PV}-${MACHINE}"
KERNEL_IMAGE_SYMLINK_NAME = "kexecboot-${MACHINE}"

INITRAMFS_IMAGE = "initramfs-kexecboot-klibc-image"
INITRAMFS_TASK = "${INITRAMFS_IMAGE}:do_image_complete"

# disable unneeded tasks
do_shared_workdir[noexec] = "1"
do_install[noexec] = "1"
do_package[noexec] = "1"
do_package_qa[noexec] = "1"
do_packagedata[noexec] = "1"
do_package_deb[noexec] = "1"
do_package_ipk[noexec] = "1"
do_package_rpm[noexec] = "1"
do_package_tar[noexec] = "1"
do_package_write_deb[noexec] = "1"
do_package_write_ipk[noexec] = "1"
do_package_write_rpm[noexec] = "1"
do_package_write_tar[noexec] = "1"
do_populate_sysroot[noexec] = "1"