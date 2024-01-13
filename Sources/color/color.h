#ifndef mthcolor_h
#define mthcolor_h

// Make sure that the output buffer is 6 times larger than the input buffer.

// colors should either be
//    0 for no colors
//   16 for ansi colors
//  256 for xterm 256 colors
// 4096 for xterm true colors
int substitute_color(char *input, char *output, int colors);

/*
    For xterm true color foreground colors use <F000> to <FFFF>
    For xterm true color background colors use <B000> to <BFFF>

    With true colors disabled colors are converted to xterm 256 colors.

    With 256 colors disabled colors are converted to 16 color ANSI.

    With 16 colors disabled color codes are stripped.

    4096 colors are a maximum of 16 bytes.
    256 colors are a maximum of 11 bytes.
    16 colors are a maximum of 8 bytes.
*/

/*
    For MUD 32 color codes use:

    ^a - dark azure                 ^A - azure
    ^b - dark blue                  ^B - blue
    ^c - dark cyan                  ^C - cyan
    ^e - dark ebony                 ^E - ebony
    ^g - dark green                 ^G - green
    ^j - dark jade                  ^J - jade
    ^l - dark lime                  ^L - lime
    ^m - dark magenta               ^M - magenta
    ^o - dark orange                ^O - orange
    ^p - dark pink                  ^P - pink
    ^r - dark red                   ^R - red
    ^s - dark silver                ^S - silver
    ^t - dark tan                   ^T - tan
    ^v - dark violet                ^V - violet
    ^w - dark white                 ^W - white
    ^y - dark yellow                ^Y - yellow

    ^? - random color

    With 256 colors disabled colors are converted to 16 color ANSI.
*/


// 256 to 16 foreground color conversion table

char *ansi_colors_f[256] =
{
    "\e[22;30m", "\e[22;31m", "\e[22;32m", "\e[22;33m", "\e[22;34m", "\e[22;35m", "\e[22;36m", "\e[22;37m",
    "\e[1;30m",  "\e[1;31m",  "\e[1;32m",  "\e[1;33m",   "\e[1;34m",  "\e[1;35m",  "\e[1;36m",  "\e[1;37m",

    "\e[22;30m", "\e[22;34m", "\e[22;34m", "\e[22;34m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;32m", "\e[22;36m", "\e[22;36m", "\e[22;34m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;32m", "\e[22;36m", "\e[22;36m", "\e[22;36m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;32m", "\e[22;32m", "\e[22;36m", "\e[22;36m", "\e[22;36m",  "\e[1;36m",
     "\e[1;32m",  "\e[1;32m",  "\e[1;32m", "\e[22;36m",  "\e[1;36m",  "\e[1;36m",
     "\e[1;32m",  "\e[1;32m",  "\e[1;32m",  "\e[1;36m",  "\e[1;36m",  "\e[1;36m",

    "\e[22;31m", "\e[22;35m", "\e[22;35m", "\e[22;34m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;33m",  "\e[1;30m", "\e[22;34m", "\e[22;34m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;33m", "\e[22;32m", "\e[22;36m", "\e[22;36m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;32m", "\e[22;32m", "\e[22;36m", "\e[22;36m", "\e[22;36m",  "\e[1;36m",
     "\e[1;32m",  "\e[1;32m",  "\e[1;32m", "\e[22;36m",  "\e[1;36m",  "\e[1;36m",
     "\e[1;32m",  "\e[1;32m",  "\e[1;32m",  "\e[1;36m",  "\e[1;36m",  "\e[1;36m",

    "\e[22;31m", "\e[22;35m", "\e[22;35m", "\e[22;35m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;33m", "\e[22;31m", "\e[22;35m", "\e[22;35m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;33m", "\e[22;33m", "\e[22;37m", "\e[22;34m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;33m", "\e[22;33m", "\e[22;32m", "\e[22;36m", "\e[22;36m",  "\e[1;34m",
     "\e[1;32m",  "\e[1;32m",  "\e[1;32m", "\e[22;36m",  "\e[1;36m",  "\e[1;36m",
     "\e[1;32m",  "\e[1;32m",  "\e[1;32m",  "\e[1;32m",  "\e[1;36m",  "\e[1;36m",

    "\e[22;31m", "\e[22;31m", "\e[22;35m", "\e[22;35m", "\e[22;35m",  "\e[1;35m",
    "\e[22;31m", "\e[22;31m", "\e[22;35m", "\e[22;35m", "\e[22;35m",  "\e[1;35m",
    "\e[22;33m", "\e[22;33m", "\e[22;31m", "\e[22;35m", "\e[22;35m",  "\e[1;34m",
    "\e[22;33m", "\e[22;33m", "\e[22;33m", "\e[22;37m",  "\e[1;34m",  "\e[1;34m",
    "\e[22;33m", "\e[22;33m", "\e[22;33m",  "\e[1;32m",  "\e[1;36m",  "\e[1;36m",
     "\e[1;33m",  "\e[1;33m",  "\e[1;32m",  "\e[1;32m",  "\e[1;36m",  "\e[1;36m",

     "\e[1;31m",  "\e[1;31m",  "\e[1;31m", "\e[22;35m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;31m",  "\e[1;31m",  "\e[1;31m", "\e[22;35m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;31m",  "\e[1;31m",  "\e[1;31m", "\e[22;35m",  "\e[1;35m",  "\e[1;35m",
    "\e[22;33m", "\e[22;33m", "\e[22;33m",  "\e[1;31m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;37m",  "\e[1;37m",
     "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;37m",  "\e[1;37m",

     "\e[1;31m",  "\e[1;31m",  "\e[1;31m",  "\e[1;35m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;31m",  "\e[1;31m",  "\e[1;31m",  "\e[1;35m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;31m",  "\e[1;31m",  "\e[1;31m",  "\e[1;31m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;33m",  "\e[1;33m",  "\e[1;31m",  "\e[1;31m",  "\e[1;35m",  "\e[1;35m",
     "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;37m",  "\e[1;37m",
     "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;33m",  "\e[1;37m",  "\e[1;37m",

     "\e[1;30m",  "\e[1;30m",  "\e[1;30m",  "\e[1;30m",  "\e[1;30m",  "\e[1;30m",
     "\e[1;30m",  "\e[1;30m",  "\e[1;30m",  "\e[1;30m",  "\e[1;30m",  "\e[1;30m",
    "\e[22;37m", "\e[22;37m", "\e[22;37m", "\e[22;37m", "\e[22;37m", "\e[22;37m",
     "\e[1;37m",  "\e[1;37m",  "\e[1;37m",  "\e[1;37m",  "\e[1;37m",  "\e[1;37m"
};

char *ansi_colors_b[256] =
{
    "\e[40m", "\e[41m", "\e[42m", "\e[43m", "\e[44m", "\e[45m", "\e[46m", "\e[47m",
    "\e[40m", "\e[41m", "\e[42m", "\e[43m", "\e[44m", "\e[45m", "\e[46m", "\e[47m",

    "\e[40m", "\e[44m", "\e[44m", "\e[44m", "\e[44m", "\e[44m",
    "\e[42m", "\e[46m", "\e[46m", "\e[44m", "\e[44m", "\e[44m",
    "\e[42m", "\e[46m", "\e[46m", "\e[46m", "\e[44m", "\e[44m",
    "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m", "\e[46m",
    "\e[42m", "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m",
    "\e[42m", "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m",

    "\e[41m", "\e[45m", "\e[45m", "\e[44m", "\e[44m", "\e[44m",
    "\e[43m", "\e[40m", "\e[44m", "\e[44m", "\e[44m", "\e[44m",
    "\e[43m", "\e[42m", "\e[46m", "\e[46m", "\e[44m", "\e[44m",
    "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m", "\e[46m",
    "\e[42m", "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m",
    "\e[42m", "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m",

    "\e[41m", "\e[45m", "\e[45m", "\e[45m", "\e[44m", "\e[44m",
    "\e[43m", "\e[41m", "\e[45m", "\e[45m", "\e[44m", "\e[44m",
    "\e[43m", "\e[43m", "\e[47m", "\e[44m", "\e[44m", "\e[44m",
    "\e[43m", "\e[43m", "\e[42m", "\e[46m", "\e[46m", "\e[44m",
    "\e[42m", "\e[42m", "\e[42m", "\e[46m", "\e[46m", "\e[46m",
    "\e[42m", "\e[42m", "\e[42m", "\e[42m", "\e[46m", "\e[46m",

    "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m", "\e[45m",
    "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m", "\e[45m",
    "\e[43m", "\e[43m", "\e[41m", "\e[45m", "\e[45m", "\e[44m",
    "\e[43m", "\e[43m", "\e[43m", "\e[47m", "\e[44m", "\e[44m",
    "\e[43m", "\e[43m", "\e[43m", "\e[42m", "\e[46m", "\e[46m",
    "\e[43m", "\e[43m", "\e[42m", "\e[42m", "\e[46m", "\e[46m",

    "\e[41m", "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m",
    "\e[41m", "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m",
    "\e[41m", "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m",
    "\e[43m", "\e[43m", "\e[43m", "\e[41m", "\e[45m", "\e[45m",
    "\e[43m", "\e[43m", "\e[43m", "\e[43m", "\e[47m", "\e[47m",
    "\e[43m", "\e[43m", "\e[43m", "\e[43m", "\e[47m", "\e[47m",

    "\e[41m", "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m",
    "\e[41m", "\e[41m", "\e[41m", "\e[45m", "\e[45m", "\e[45m",
    "\e[41m", "\e[41m", "\e[41m", "\e[41m", "\e[45m", "\e[45m",
    "\e[43m", "\e[43m", "\e[41m", "\e[41m", "\e[45m", "\e[45m",
    "\e[43m", "\e[43m", "\e[43m", "\e[43m", "\e[47m", "\e[47m",
    "\e[43m", "\e[43m", "\e[43m", "\e[43m", "\e[47m", "\e[47m",

    "\e[40m", "\e[40m", "\e[40m", "\e[40m", "\e[40m", "\e[40m",
    "\e[40m", "\e[40m", "\e[40m", "\e[40m", "\e[40m", "\e[40m",
    "\e[47m", "\e[47m", "\e[47m", "\e[47m", "\e[47m", "\e[47m",
    "\e[47m", "\e[47m", "\e[47m", "\e[47m", "\e[47m", "\e[47m"
};

// 0 1 2 3 4 5 6 7 8 9 A B C D E F
// 0 1 1 1 1 1 1 2 2 3 3 3 4 4 4 5

// 4096 to 256 color conversion table

unsigned char x_256color_values[256] =
{
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   1,   1,   1,   1,   1,   1,   2,   2,   3,   0,   0,   0,   0,   0,   0,
      0,   3,   3,   4,   4,   4,   5,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   3,   3,   4,   4,   4,   5,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0
};

// 4096 to 256 color conversion function

int x_256c_val(char chr)
{
    return (int) x_256color_values[(unsigned char) chr];
}

// 256 color random color function

int x_256c_rnd()
{
    return rand() % 216 + 16;
}

// 16777216 to 4096 color conversion table

unsigned char truecolor_values[256] =
{
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,  17,  34,  51,   68,  85, 102, 119, 136, 153,    0,   0,   0,   0,   0,   0,
      0, 170, 187, 204,  221, 238, 255,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0, 170, 187, 204,  221, 238, 255,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,    0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0
};

// 16777216 to 4096 color conversion function

int tc_val(char chr)
{
    return (int) truecolor_values[(unsigned char) chr];
}

// random color table

char dec_to_hex[16] =
{
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'
};

// random color function

char *tc_rnd()
{
    static char rnd_col[7];

    sprintf(rnd_col, "<F%c%c%c>", dec_to_hex[rand() % 16], dec_to_hex[rand() % 16], dec_to_hex[rand() % 16]);

    return rnd_col;
}

// 32 color lookup table

unsigned char m_32color_values[256] =
{
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,  '?',
      0,  'A',  1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
      1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   0,   0,   0,   0,   0,
      0,  'a',  1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
      1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0
};

// 32 color lookup function

int is_32c(char chr)
{
    return (int) m_32color_values[(unsigned char) chr];
}


// 32 to 4096 color conversion tables

char *alphabet_fgc_dark[26] =
{
    "<f06b>", "<f00b>", "<f0bb>", "", "<f000>", "", "<f0b0>", "", "", "<f0b6>", "", "<f6b0>", "<fb0b>",
    "", "<fb60>", "<fb06>", "", "<fb00>", "<f888>", "<f860>", "", "<f60b>", "<fbbb>", "", "<fbb0>", ""
};

char *alphabet_fgc_bold[26] =
{
    "<f08f>", "<f00f>", "<f0ff>", "", "<f666>", "", "<f0f0>", "", "", "<f0f8>", "", "<f8f0>", "<ff0f>",
    "", "<ff80>", "<ff08>", "", "<ff00>", "<fddd>", "<fdb0>", "", "<f80f>", "<ffff>", "", "<fff0>", ""
};

#endif /* mthcolor_h */
