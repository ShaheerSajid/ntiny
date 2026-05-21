/*
 * libstubs.c — minimal libc surface for FreeRTOS without newlib.
 *
 * We link with -nostdlib so the toolchain doesn't drag in newlib. The
 * kernel still references memset/memcpy (in prvCreateStaticTask, queue
 * copy, etc.) and a few mem ops, so provide tiny portable versions.
 */

#include <stddef.h>
#include <stdint.h>

void * memset( void * dest, int c, size_t n )
{
    unsigned char * d = ( unsigned char * ) dest;
    while( n-- )
        *d++ = ( unsigned char ) c;
    return dest;
}

void * memcpy( void * dest, const void * src, size_t n )
{
    unsigned char * d = ( unsigned char * ) dest;
    const unsigned char * s = ( const unsigned char * ) src;
    while( n-- )
        *d++ = *s++;
    return dest;
}

void * memmove( void * dest, const void * src, size_t n )
{
    unsigned char * d = ( unsigned char * ) dest;
    const unsigned char * s = ( const unsigned char * ) src;
    if( d < s ) {
        while( n-- )
            *d++ = *s++;
    } else {
        d += n;
        s += n;
        while( n-- )
            *--d = *--s;
    }
    return dest;
}

int memcmp( const void * a, const void * b, size_t n )
{
    const unsigned char * ua = a;
    const unsigned char * ub = b;
    while( n-- ) {
        if( *ua != *ub )
            return ( int ) *ua - ( int ) *ub;
        ua++; ub++;
    }
    return 0;
}

size_t strlen( const char * s )
{
    const char * p = s;
    while( *p )
        p++;
    return ( size_t )( p - s );
}
