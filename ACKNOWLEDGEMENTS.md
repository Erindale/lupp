# Acknowledgements

Lupp vendors no third-party code and has no package dependencies. It does
implement several published algorithms, and this is where they came from.

Mathematical formulas aren't copyrightable — the expression of them is — and
everything below is written from scratch in Metal or Swift. These credits are
here because the ideas are not mine and the people who worked them out deserve
naming, not because a licence forces it.

## Colour transforms

**Tetrahedral interpolation** — after
[TetraInterp](https://github.com/hotgluebanjo/TetraInterp-DCTL) by hotgluebanjo,
MIT licensed. The six-tetrahedra decomposition of the RGB cube, and the choice to
fix black, white and the grey axis so neutrals can't be pushed off neutral, are
theirs. Lupp's shader is an independent implementation of that approach, and the
parameter layout follows the same order Resolve shows for the DCTL.

**AgX** — an analytic approximation of the AgX view transform originated by Troy
Sobotka, using the inset/outset matrices and contrast polynomial that circulate
in the three.js and Godot implementations (both MIT). It approximates AgX Base;
it is not the reference LUTs and will not match them exactly.

**ACES Filmic** — the RRT + ODT curve fit by Stephen Hill, itself building on
Krzysztof Narkowicz's approximation, with the sRGB↔AP1 matrices. An approximation
of the ACES rendering, not the reference transforms. ACES is a project of the
Academy of Motion Picture Arts and Sciences.

**CIE 1931 spectral locus** — computed from the multi-lobe Gaussian fit to the
1931 2° colour matching functions in *Simple Analytic Approximations to the CIE
XYZ Color Matching Functions*, Wyman, Sloan & Shirley, Journal of Computer
Graphics Techniques 2 (2), 2013.

## Camera log encodings

The transfer curves for **S-Log3**, **LogC3**, **V-Log** and **ACEScct** are
implemented from each vendor's published specification.

S-Log3 and S-Gamut3 are trademarks of Sony. LogC and ARRI are trademarks of
Arnold & Richter Cine Technik. V-Log is a trademark of Panasonic. ACES is a
trademark of the Academy of Motion Picture Arts and Sciences. They are named here
only to say which encoding Lupp implements. Lupp is not affiliated with, endorsed
by, or certified by any of them, and implementing a published curve is not a
claim that the result is qualified for any of their workflows.

## Formats

**`.cube` LUTs** follow the Adobe Cube LUT Specification 1.0, also known as the
IRIDAS cube format.

## System frameworks

Decoding, colour conversion and rendering are Apple's: ImageIO, Core Graphics,
Metal, Accelerate and AppKit. The 62 image formats Lupp opens are whatever
ImageIO on your machine can decode — none of that support is Lupp's own work.
