#include <dlfcn.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	void	   *h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);

	if (h == NULL)
	{
		printf("dlopen failed: %s\n", dlerror());
		return 1;
	}
	printf("dlopen ok\n");
	return 0;
}
