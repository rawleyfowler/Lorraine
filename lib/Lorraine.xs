#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
 
#include <errno.h>
#include <sys/prctl.h>
#include <stdio.h>
#include <unistd.h>
 
#define CAP_EFFECTIVE 0
#define CAP_PERMITTED 1
#define CAP_INHERITABLE 2
 
MODULE = Lorraine     PACKAGE = Lorraine
 
int
set_child_subreaper()
    CODE:
        if(prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0))
            XSRETURN_UNDEF;
        RETVAL = 1;
    OUTPUT:
        RETVAL
