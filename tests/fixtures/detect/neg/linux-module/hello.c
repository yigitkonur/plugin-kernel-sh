#include <linux/module.h>
#include <linux/kernel.h>
static int __init hello_init(void) { printk(KERN_INFO "kernel module loaded\n"); return 0; }
module_init(hello_init);
MODULE_LICENSE("GPL");
