# Scanline Classic

Version 1.0
README Edition 1

Copyright (C) 2023 W. M. Martinez
Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

A general purpose RetroArch shader with an emphasis on realism while
maintaining a high degree of flexibility and aesthetic quality.

## Installation

Simply copy all SLANGP files and the src/ directory to a folder in your
shader directory and configure RetroArch to load the SLANGP file as
needed.  If you need additional help, check the RetroArch documentation.

## Usage

The following presets are provided:

* scanline-advanced.slangp: Provides all possible parameters, enabling
  the most flexibility at the cost of performance and complexity.

The following shaders are provided:

* scanline-advanced.slang: Advanced, general purpose shader with all
  possibilites.

The following headers are provide:

* color.h: Color correction functions

* common.h: General purpose convenience variables and functions

* geometry.h: Operations related to geometry, simulating
  three-dimensional screen distortions

* filter.h: Operations for upscaling

## Bugs

Report bugs to [W. M. Martinez](mailto:anikom15@outlook.com).

## Credits

Design and Programming
* W. M. Martinez

Original Mitchell-Netravali Shader Authors
* [Team XBMC](http://www.xbmc.org)
* [Stefanos A.](http://www.opentk.com)

## User's Manual

### Signal Options

#### ON_PIXELS and OFF_PIXELS

Represents the ratio of visible scanlines vs. blank scanlines, as
defined by the vertical resolution of the simulated display.  Nearly all
arcade games and consoles in the 20th century displayed a progressive
scan signal using half of the lines allowed by standard 15 kHz displays.
This technique is colloquially referred as '240p'.  To simulate this
mode, both ON_PIXELS and OFF_PIXELS should be set to 1.0.

Some games and computers (like the compact Apple Macintoshes) used what
is known as 'medium res' monitors.  These monitors increase the
progressive scan resolution from ~240 lines to ~384.  These monitors
generally used the same components as the 15 kHz monitors, just with
a higher scanrate.  In this case, the electron beam spot size should
be the same relative size, and the blank scanlines should appear
smaller.  This can be achieved by setting ON_PIXELS to 3.0 and
OFF_PIXELS to 2.0.

Some displays have very nonlinear voltage characteristics resulting in
a wide variety of distortions, including things referred to as
'blooming' which greatly inhibits the display of the scanline effect.
Scanline Classic is intended to simulate *well-behaved* displays, and
nothing further will be discussed or developed on the simulation of
these kinds of faults.

31 kHz monitors are also known as 'hi res' and 'VGA' monitors.  These
monitors support 480p.  They usually can display 15 kHz and 22 kHz
signals as well.  22 kHz modes are always done by simply scanning the
lines, which results in 3:2 scanline effect described above.  15 kHz
signals are handled in one of two possible ways.  The first is exactly
the same as the 22 kHz mode, and scanlines will be visible in a 1:1
ratio.  The second is referred to as *line doubling*.  The monitor
actually displays a 31 kHz signal where each line is displayed twice.
This can be accomplished by setting ON_PIXELS to 2.0 and OFF_PIXELS to
0.0.  The 31 kHz (and any greater resolution) signal should be
simulated by setting ON_PIXELS to 1.0 and OFF_PIXELS to 0.0.

Interlaced content will be discussed in the HI_RES_THRES section.

##### Recommendations

15 kHz signals:
* ON_PIXELS: 1.0
* OFF_PIXELS: 1.0

22 kHz signals:
* ON_PIXELS: 3.0
* OFF_PIXELS: 2.0

31 kHz signals:
* ON_PIXELS: 1.0
* OFF_PIXELS: 0.0

15 kHz signals on 31 kHz displays (i.e. VGA DOS games):
* ON_PIXELS: 2.0
* OFF_PIXELS: 0.0

#### H_FRONT, H_BACK, V_FRONT, V_BACK:

Represents the front and back porches for the horizontal and vertical
parts of the signal, in pixels.  These values vary per system and are
not standardized, so care should be taken.  If the values aren't known,
it's probably best to set them reasonable values based on a video
standard like NTSC or PAL.

Currently these parameters simply compensate for the geometry
functions.  Higher values results in less distortion, because the
extremes of the picture area (where the distortion is most), is getting
replaced by black.  Note that these parameters do not scale the picture
in any way.  They simply affect the math applied in the geometry
section of the shader.  This allows you to experiment with values
without risk of affecting the aspect ratio.

##### Recommendations

Famicom and Super Famicom:
* H_FRONT: 20.0
* H_BACK: 40.0
* V_FRONT: 5
* V_BACK: 14.0

VGA:
* H_FRONT: 16
* H_BACK: 48
* V_FRONT: 10
* V_BACK: 33.0

### Color Correction Options

These options are quite complex and require a study of color theory.  It
is recommended to not tune these settings by eye, but rather to use test
patterns (like those found in arcade game test modes and the 240p Test
ROMs) and colorimeters. Poorly chosen settings may make it difficult to
distinguish all colors.

#### TRANSFER_FUNCTION

Selects the transfer function used to make color signals linear.
Currently, 1.0 is used for video content and 2.0 is used for sRGB.

##### Recommendations

Use 1.0 unless you know what you're doing.

#### COLOR_MODE

There are three color correction modes available.  1.0 and 2.0 are both
grayscale, where 1.0 use a single phosphor model while 2.0 uses a
dual-phosphor model.  3.0 is for color monitors using three primaries.

##### Recommendations

Use either 1.0 or 2.0 for monochrome content and 3.0 for color content.
For a simple simulation of something like a green or amber monitor, 1.0
can be used.  To simulate the 'page white' phosphors used by systems
like the compact Apple Macintoshes, 2.0 can be easier to use, though
theoretically 1.0 is possible.

#### LUMINANCE_WEIGHT_*c*

When a monochrome signal is needed, a weight is applied to each RGB
component of the original signal.  These parameters specify the weight
used for this conversion.

These weights are usually specified in standards.  However, some
standards specify the weight in *gamma-corrected space,* and these
weights are useless for our purposes.  Instead, use the
phosphorweights.R script to determine appropriate weights for a given
color system model.  It is convention to round these values to four
decimal places.

##### Recommendations

Rec. BT.601 (SD) content:
* R: 0.2124
* G: 0.7011
* B: 0.0866

Rec. BT.709/sRGB (HD) content:
* R: 0.2126
* G: 0.7152
* B: 0.0722

#### CHROMA_*n*_X, CHROMA_*n*_Y, CHROMA_*n*_WEIGHT

X and Y are chromaticity coordinates for the *n*th primary.  WEIGHT is
the relative intensity of the primary, and will affect the white point.

Only *A* is used in color mode 1.  In color mode 2, *A* and *B* are
used.  In color mode 3, all chromaticities are used.

##### Recommendations

For a typical 20th century 60 Hz system (BT.601):
* COLOR_MODE: 3.0
* CHROMA_A_X: 0.630
* CHROMA_A_Y: 0.340
* CHROMA_B_X: 0.310
* CHROMA_B_Y: 0.595
* CHROMA_C_X: 0.155
* CHROMA_C_Y: 0.070
* CHROMA_A_WEIGHT: 0.2124
* CHROMA_B_WEIGHT: 0.7011
* CHROMA_C_WEIGHT: 0.0866

For PAL (50 Hz) systems (BT.601):
* COLOR_MODE: 3.0
* CHROMA_A_X: 0.640
* CHROMA_A_Y: 0.330
* CHROMA_B_X: 0.290
* CHROMA_B_Y: 0.600
* CHROMA_C_X: 0.150
* CHROMA_C_Y: 0.060
* CHROMA_A_WEIGHT: 0.2220
* CHROMA_B_WEIGHT: 0.7066
* CHROMA_C_WEIGHT: 0.0713

For a green monochrome monitor:
* COLOR_MODE: 1.0
* CHROMA_A_X: 0.218
* CHROMA_A_Y: 0.712
* CHROMA_A_WEIGHT: 1.0

For a slightly less green monochrome monitor:
* COLOR_MODE: 1.0
* CHROMA_A_X: 0.279
* CHROMA_A_Y: 0.534
* CHROMA_A_WEIGHT: 1.0

For an amber monitor:
* COLOR_MODE: 1.0
* CHROMA_A_X: 0.523
* CHROMA_A_Y: 0.469
* CHROMA_A_WEIGHT: 1.0

For a 'page white' monochrome monitor:
* COLOR_MODE: 2.0
* CHROMA_A_X: 0.523
* CHROMA_A_Y: 0.469
* CHROMA_B_X: 0.265
* CHROMA_B_Y: 0.285A
* CHROMA_A_WEIGHT: 0.2
* CHROMA_B_WEIGHT: 0.8

For HD/sRGB systems (BT.709):
* COLOR_MODE: 3.0
* CHROMA_A_X: 0.640
* CHROMA_A_Y: 0.330
* CHROMA_B_X: 0.300
* CHROMA_B_Y: 0.600
* CHROMA_C_X: 0.150
* CHROMA_C_Y: 0.060
* CHROMA_A_WEIGHT: 0.2126
* CHROMA_B_WEIGHT: 0.7152
* CHROMA_C_WEIGHT: 0.0722

#### SCALE_W

Determines if white point auto-scaling should be enabled.  1.0 is on
and 0.0 is off.  The auto-scaler determines the maximum R, G, and B
component for a given luminance of 1.0 and scales the output according
to the largest value.  This ensures that no clipping occurs while
ensuring the maximum possible dynamic range.

##### Recommendations

Leave this value at 1.0 unless dynamic range is very poor.  A ramp test
should be used to ensure a smooth grayscale is possible.  It's better
to raise your monitor backlight to compensate for lost brightness than
to disable this setting.  In a dim environment, 100 nits of brightness
at 2.4 gamma is more than enough.

### CRT Simulation Options

#### FOCUS

Simulates the beam focus of a CRT, but it doesn't attempt to emulate
any realistic model, as this is far too complex.  Instead it simply
affects the coefficients used for the Mitchell-Netravali upscaler.
Higher values are sharper whereas lower values are blurrier.

##### Recommendations

Using 0.5 will give a very aesthetic, Trinitron-like look.  Lower
values will look more like a shadow mask or slot mask.  You can use
1.0 for monochrome CRTs, as those have sharp picure quality.

#### HI_RES_THRES

Threshold for interlaced content.  If the original vertical resolution
(i.e. the actual resolution of the emulator) is greater than this
threshold, the image will be interlaced by alternating blank scanlines
placed directly over half of the content.  Care should be taken that the
content you are playing is supposed to be interlaced.  Systems like the
SFC, N64, PlayStation, and GameCube all supported interlaced modes.

##### Recommendations

Leave at 400.0, but if you are emulating progressive content (like PCs),
raise this to ensure your signals don't get interlaced.

#### PIN_DISTORTION_TYPE

There are two types of CRT deflection methods: electrostatic and
magnetic.  Electrostatic is linear, while magnetic is nonlinear.  Only
very small CRTs employ electrostatic deflection.

##### Recommendations

Leave at 1.0.  Electrostatic deflection was really only used for
electronic test equipment.

#### DEFLECTION_ANGLE

This is twice the maximum angle of deflection of the CRT, or
essentially the angle made by the tube of the CRT.

##### Recommendations

Anything from 60° to 125° is sensible.  Newer CRTs have larger angles.

#### SCREEN_ANGLE_X, SCREEN_ANGLE_Y

The angle formed by the actual curvature of the screen in either
direction.  In practice, this was always significantly less that the
tube angle.

##### Recommendations

Display a crosshatch test pattern, ideally with unsafe areas marked
(usually in red).  Set the deflection angle first, then set the screen
angles so that all the lines in the white area are visibly straight.
You may then adjust all the settings gradually to get the distortion
you see fit.  For monitors, increase UNDERSCAN a bit.  Use ZOOM to get
the desired picture size.

Typical 'bubble' CRT:
* DEFLECTION_ANGLE: 90
* SCREEN_ANGLE: 60.0
* SCREEN_ANGLE: 60.0
* ZOOM: 1.08

For a curved Trinitron:
* DEFLECTION_ANGLE: 90.0
* SCREEN_ANGLE_X: 60.0
* SCREEN_ANGLE_Y: 30.0
* ZOOM: 1.08

Flatscreen:
* DEFLECTION_ANGLE: 0.0
* SCREEN_ANGLE_X: 0.0
* SCREEN_ANGLE_Y: 0.0
* ZOOM: 1.0

Computer monitor:
* DEFLECTION_ANGLE: 60.0
* SCREEN_ANGLE: 30.0
* SCREEN_ANGLE: 30.0
* UNDERSCAN: 10.0
* ZOOM: 1.1

#### X_COMP, Y_COMP

Simulates a rather simple pincushion compensation circuit.

##### Recommendations

May be left at 0.0, or may be arbitrarily set for a desired effect.

#### UNDERSCAN

This is similar to the signal porch settings but scales the piture so
that it actually appears smaller.  By displaying the picture in a
smaller box, the effects of geometric distortion is lessened.  Arcade
monitors and televisions didn't do this, but broadcast monitors and
computer monitors provided settings to allow the user to display an
underscanned image.

##### Recommendations

When emulating computers and using the other geometry settings, it's
best to set this to around 10.0.

### Output Settings

These settings do not have recommendations as they do not relate to a
simulation, but rather are just adjustments for the output display.

#### ZOOM

This scales the picture.  When using geometry settings, parts of the
picture may get cut off, or may not fully fill the screen.  You can use
this setting to fill the screen.

#### COLOR_SPACE

At the moment, this setting is not used.  However, in the future it is
intended to allow wide gamut displays to display the content without
any additional color management.  For now, 1.0 means sRGB and the other
options do not do anything else.

## License

License information for this software can be found in the COPYING file.

### GNU Free Documentation License

Version 1.3, 3 November 2008

Copyright (C) 2000, 2001, 2002, 2007, 2008 Free Software Foundation,
Inc. <https://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

#### 0. PREAMBLE

The purpose of this License is to make a manual, textbook, or other
functional and useful document "free" in the sense of freedom: to
assure everyone the effective freedom to copy and redistribute it,
with or without modifying it, either commercially or noncommercially.
Secondarily, this License preserves for the author and publisher a way
to get credit for their work, while not being considered responsible
for modifications made by others.

This License is a kind of "copyleft", which means that derivative
works of the document must themselves be free in the same sense. It
complements the GNU General Public License, which is a copyleft
license designed for free software.

We have designed this License in order to use it for manuals for free
software, because free software needs free documentation: a free
program should come with manuals providing the same freedoms that the
software does. But this License is not limited to software manuals; it
can be used for any textual work, regardless of subject matter or
whether it is published as a printed book. We recommend this License
principally for works whose purpose is instruction or reference.

#### 1. APPLICABILITY AND DEFINITIONS

This License applies to any manual or other work, in any medium, that
contains a notice placed by the copyright holder saying it can be
distributed under the terms of this License. Such a notice grants a
world-wide, royalty-free license, unlimited in duration, to use that
work under the conditions stated herein. The "Document", below, refers
to any such manual or work. Any member of the public is a licensee,
and is addressed as "you". You accept the license if you copy, modify
or distribute the work in a way requiring permission under copyright
law.

A "Modified Version" of the Document means any work containing the
Document or a portion of it, either copied verbatim, or with
modifications and/or translated into another language.

A "Secondary Section" is a named appendix or a front-matter section of
the Document that deals exclusively with the relationship of the
publishers or authors of the Document to the Document's overall
subject (or to related matters) and contains nothing that could fall
directly within that overall subject. (Thus, if the Document is in
part a textbook of mathematics, a Secondary Section may not explain
any mathematics.) The relationship could be a matter of historical
connection with the subject or with related matters, or of legal,
commercial, philosophical, ethical or political position regarding
them.

The "Invariant Sections" are certain Secondary Sections whose titles
are designated, as being those of Invariant Sections, in the notice
that says that the Document is released under this License. If a
section does not fit the above definition of Secondary then it is not
allowed to be designated as Invariant. The Document may contain zero
Invariant Sections. If the Document does not identify any Invariant
Sections then there are none.

The "Cover Texts" are certain short passages of text that are listed,
as Front-Cover Texts or Back-Cover Texts, in the notice that says that
the Document is released under this License. A Front-Cover Text may be
at most 5 words, and a Back-Cover Text may be at most 25 words.

A "Transparent" copy of the Document means a machine-readable copy,
represented in a format whose specification is available to the
general public, that is suitable for revising the document
straightforwardly with generic text editors or (for images composed of
pixels) generic paint programs or (for drawings) some widely available
drawing editor, and that is suitable for input to text formatters or
for automatic translation to a variety of formats suitable for input
to text formatters. A copy made in an otherwise Transparent file
format whose markup, or absence of markup, has been arranged to thwart
or discourage subsequent modification by readers is not Transparent.
An image format is not Transparent if used for any substantial amount
of text. A copy that is not "Transparent" is called "Opaque".

Examples of suitable formats for Transparent copies include plain
ASCII without markup, Texinfo input format, LaTeX input format, SGML
or XML using a publicly available DTD, and standard-conforming simple
HTML, PostScript or PDF designed for human modification. Examples of
transparent image formats include PNG, XCF and JPG. Opaque formats
include proprietary formats that can be read and edited only by
proprietary word processors, SGML or XML for which the DTD and/or
processing tools are not generally available, and the
machine-generated HTML, PostScript or PDF produced by some word
processors for output purposes only.

The "Title Page" means, for a printed book, the title page itself,
plus such following pages as are needed to hold, legibly, the material
this License requires to appear in the title page. For works in
formats which do not have any title page as such, "Title Page" means
the text near the most prominent appearance of the work's title,
preceding the beginning of the body of the text.

The "publisher" means any person or entity that distributes copies of
the Document to the public.

A section "Entitled XYZ" means a named subunit of the Document whose
title either is precisely XYZ or contains XYZ in parentheses following
text that translates XYZ in another language. (Here XYZ stands for a
specific section name mentioned below, such as "Acknowledgements",
"Dedications", "Endorsements", or "History".) To "Preserve the Title"
of such a section when you modify the Document means that it remains a
section "Entitled XYZ" according to this definition.

The Document may include Warranty Disclaimers next to the notice which
states that this License applies to the Document. These Warranty
Disclaimers are considered to be included by reference in this
License, but only as regards disclaiming warranties: any other
implication that these Warranty Disclaimers may have is void and has
no effect on the meaning of this License.

#### 2. VERBATIM COPYING

You may copy and distribute the Document in any medium, either
commercially or noncommercially, provided that this License, the
copyright notices, and the license notice saying this License applies
to the Document are reproduced in all copies, and that you add no
other conditions whatsoever to those of this License. You may not use
technical measures to obstruct or control the reading or further
copying of the copies you make or distribute. However, you may accept
compensation in exchange for copies. If you distribute a large enough
number of copies you must also follow the conditions in section 3.

You may also lend copies, under the same conditions stated above, and
you may publicly display copies.

#### 3. COPYING IN QUANTITY

If you publish printed copies (or copies in media that commonly have
printed covers) of the Document, numbering more than 100, and the
Document's license notice requires Cover Texts, you must enclose the
copies in covers that carry, clearly and legibly, all these Cover
Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on
the back cover. Both covers must also clearly and legibly identify you
as the publisher of these copies. The front cover must present the
full title with all words of the title equally prominent and visible.
You may add other material on the covers in addition. Copying with
changes limited to the covers, as long as they preserve the title of
the Document and satisfy these conditions, can be treated as verbatim
copying in other respects.

If the required texts for either cover are too voluminous to fit
legibly, you should put the first ones listed (as many as fit
reasonably) on the actual cover, and continue the rest onto adjacent
pages.

If you publish or distribute Opaque copies of the Document numbering
more than 100, you must either include a machine-readable Transparent
copy along with each Opaque copy, or state in or with each Opaque copy
a computer-network location from which the general network-using
public has access to download using public-standard network protocols
a complete Transparent copy of the Document, free of added material.
If you use the latter option, you must take reasonably prudent steps,
when you begin distribution of Opaque copies in quantity, to ensure
that this Transparent copy will remain thus accessible at the stated
location until at least one year after the last time you distribute an
Opaque copy (directly or through your agents or retailers) of that
edition to the public.

It is requested, but not required, that you contact the authors of the
Document well before redistributing any large number of copies, to
give them a chance to provide you with an updated version of the
Document.

#### 4. MODIFICATIONS

You may copy and distribute a Modified Version of the Document under
the conditions of sections 2 and 3 above, provided that you release
the Modified Version under precisely this License, with the Modified
Version filling the role of the Document, thus licensing distribution
and modification of the Modified Version to whoever possesses a copy
of it. In addition, you must do these things in the Modified Version:

-   A. Use in the Title Page (and on the covers, if any) a title
    distinct from that of the Document, and from those of previous
    versions (which should, if there were any, be listed in the
    History section of the Document). You may use the same title as a
    previous version if the original publisher of that version
    gives permission.
-   B. List on the Title Page, as authors, one or more persons or
    entities responsible for authorship of the modifications in the
    Modified Version, together with at least five of the principal
    authors of the Document (all of its principal authors, if it has
    fewer than five), unless they release you from this requirement.
-   C. State on the Title page the name of the publisher of the
    Modified Version, as the publisher.
-   D. Preserve all the copyright notices of the Document.
-   E. Add an appropriate copyright notice for your modifications
    adjacent to the other copyright notices.
-   F. Include, immediately after the copyright notices, a license
    notice giving the public permission to use the Modified Version
    under the terms of this License, in the form shown in the
    Addendum below.
-   G. Preserve in that license notice the full lists of Invariant
    Sections and required Cover Texts given in the Document's
    license notice.
-   H. Include an unaltered copy of this License.
-   I. Preserve the section Entitled "History", Preserve its Title,
    and add to it an item stating at least the title, year, new
    authors, and publisher of the Modified Version as given on the
    Title Page. If there is no section Entitled "History" in the
    Document, create one stating the title, year, authors, and
    publisher of the Document as given on its Title Page, then add an
    item describing the Modified Version as stated in the
    previous sentence.
-   J. Preserve the network location, if any, given in the Document
    for public access to a Transparent copy of the Document, and
    likewise the network locations given in the Document for previous
    versions it was based on. These may be placed in the "History"
    section. You may omit a network location for a work that was
    published at least four years before the Document itself, or if
    the original publisher of the version it refers to
    gives permission.
-   K. For any section Entitled "Acknowledgements" or "Dedications",
    Preserve the Title of the section, and preserve in the section all
    the substance and tone of each of the contributor acknowledgements
    and/or dedications given therein.
-   L. Preserve all the Invariant Sections of the Document, unaltered
    in their text and in their titles. Section numbers or the
    equivalent are not considered part of the section titles.
-   M. Delete any section Entitled "Endorsements". Such a section may
    not be included in the Modified Version.
-   N. Do not retitle any existing section to be Entitled
    "Endorsements" or to conflict in title with any Invariant Section.
-   O. Preserve any Warranty Disclaimers.

If the Modified Version includes new front-matter sections or
appendices that qualify as Secondary Sections and contain no material
copied from the Document, you may at your option designate some or all
of these sections as invariant. To do this, add their titles to the
list of Invariant Sections in the Modified Version's license notice.
These titles must be distinct from any other section titles.

You may add a section Entitled "Endorsements", provided it contains
nothing but endorsements of your Modified Version by various
parties—for example, statements of peer review or that the text has
been approved by an organization as the authoritative definition of a
standard.

You may add a passage of up to five words as a Front-Cover Text, and a
passage of up to 25 words as a Back-Cover Text, to the end of the list
of Cover Texts in the Modified Version. Only one passage of
Front-Cover Text and one of Back-Cover Text may be added by (or
through arrangements made by) any one entity. If the Document already
includes a cover text for the same cover, previously added by you or
by arrangement made by the same entity you are acting on behalf of,
you may not add another; but you may replace the old one, on explicit
permission from the previous publisher that added the old one.

The author(s) and publisher(s) of the Document do not by this License
give permission to use their names for publicity for or to assert or
imply endorsement of any Modified Version.

#### 5. COMBINING DOCUMENTS

You may combine the Document with other documents released under this
License, under the terms defined in section 4 above for modified
versions, provided that you include in the combination all of the
Invariant Sections of all of the original documents, unmodified, and
list them all as Invariant Sections of your combined work in its
license notice, and that you preserve all their Warranty Disclaimers.

The combined work need only contain one copy of this License, and
multiple identical Invariant Sections may be replaced with a single
copy. If there are multiple Invariant Sections with the same name but
different contents, make the title of each such section unique by
adding at the end of it, in parentheses, the name of the original
author or publisher of that section if known, or else a unique number.
Make the same adjustment to the section titles in the list of
Invariant Sections in the license notice of the combined work.

In the combination, you must combine any sections Entitled "History"
in the various original documents, forming one section Entitled
"History"; likewise combine any sections Entitled "Acknowledgements",
and any sections Entitled "Dedications". You must delete all sections
Entitled "Endorsements".

#### 6. COLLECTIONS OF DOCUMENTS

You may make a collection consisting of the Document and other
documents released under this License, and replace the individual
copies of this License in the various documents with a single copy
that is included in the collection, provided that you follow the rules
of this License for verbatim copying of each of the documents in all
other respects.

You may extract a single document from such a collection, and
distribute it individually under this License, provided you insert a
copy of this License into the extracted document, and follow this
License in all other respects regarding verbatim copying of that
document.

#### 7. AGGREGATION WITH INDEPENDENT WORKS

A compilation of the Document or its derivatives with other separate
and independent documents or works, in or on a volume of a storage or
distribution medium, is called an "aggregate" if the copyright
resulting from the compilation is not used to limit the legal rights
of the compilation's users beyond what the individual works permit.
When the Document is included in an aggregate, this License does not
apply to the other works in the aggregate which are not themselves
derivative works of the Document.

If the Cover Text requirement of section 3 is applicable to these
copies of the Document, then if the Document is less than one half of
the entire aggregate, the Document's Cover Texts may be placed on
covers that bracket the Document within the aggregate, or the
electronic equivalent of covers if the Document is in electronic form.
Otherwise they must appear on printed covers that bracket the whole
aggregate.

#### 8. TRANSLATION

Translation is considered a kind of modification, so you may
distribute translations of the Document under the terms of section 4.
Replacing Invariant Sections with translations requires special
permission from their copyright holders, but you may include
translations of some or all Invariant Sections in addition to the
original versions of these Invariant Sections. You may include a
translation of this License, and all the license notices in the
Document, and any Warranty Disclaimers, provided that you also include
the original English version of this License and the original versions
of those notices and disclaimers. In case of a disagreement between
the translation and the original version of this License or a notice
or disclaimer, the original version will prevail.

If a section in the Document is Entitled "Acknowledgements",
"Dedications", or "History", the requirement (section 4) to Preserve
its Title (section 1) will typically require changing the actual
title.

#### 9. TERMINATION

You may not copy, modify, sublicense, or distribute the Document
except as expressly provided under this License. Any attempt otherwise
to copy, modify, sublicense, or distribute it is void, and will
automatically terminate your rights under this License.

However, if you cease all violation of this License, then your license
from a particular copyright holder is reinstated (a) provisionally,
unless and until the copyright holder explicitly and finally
terminates your license, and (b) permanently, if the copyright holder
fails to notify you of the violation by some reasonable means prior to
60 days after the cessation.

Moreover, your license from a particular copyright holder is
reinstated permanently if the copyright holder notifies you of the
violation by some reasonable means, this is the first time you have
received notice of violation of this License (for any work) from that
copyright holder, and you cure the violation prior to 30 days after
your receipt of the notice.

Termination of your rights under this section does not terminate the
licenses of parties who have received copies or rights from you under
this License. If your rights have been terminated and not permanently
reinstated, receipt of a copy of some or all of the same material does
not give you any rights to use it.

#### 10. FUTURE REVISIONS OF THIS LICENSE

The Free Software Foundation may publish new, revised versions of the
GNU Free Documentation License from time to time. Such new versions
will be similar in spirit to the present version, but may differ in
detail to address new problems or concerns. See
<https://www.gnu.org/licenses/>.

Each version of the License is given a distinguishing version number.
If the Document specifies that a particular numbered version of this
License "or any later version" applies to it, you have the option of
following the terms and conditions either of that specified version or
of any later version that has been published (not as a draft) by the
Free Software Foundation. If the Document does not specify a version
number of this License, you may choose any version ever published (not
as a draft) by the Free Software Foundation. If the Document specifies
that a proxy can decide which future versions of this License can be
used, that proxy's public statement of acceptance of a version
permanently authorizes you to choose that version for the Document.

#### 11. RELICENSING

"Massive Multiauthor Collaboration Site" (or "MMC Site") means any
World Wide Web server that publishes copyrightable works and also
provides prominent facilities for anybody to edit those works. A
public wiki that anybody can edit is an example of such a server. A
"Massive Multiauthor Collaboration" (or "MMC") contained in the site
means any set of copyrightable works thus published on the MMC site.

"CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0
license published by Creative Commons Corporation, a not-for-profit
corporation with a principal place of business in San Francisco,
California, as well as future copyleft versions of that license
published by that same organization.

"Incorporate" means to publish or republish a Document, in whole or in
part, as part of another Document.

An MMC is "eligible for relicensing" if it is licensed under this
License, and if all works that were first published under this License
somewhere other than this MMC, and subsequently incorporated in whole
or in part into the MMC, (1) had no cover texts or invariant sections,
and (2) were thus incorporated prior to November 1, 2008.

The operator of an MMC Site may republish an MMC contained in the site
under CC-BY-SA on the same site at any time before August 1, 2009,
provided the MMC is eligible for relicensing.

### ADDENDUM: How to use this License for your documents

To use this License in a document you have written, include a copy of
the License in the document and put the following copyright and
license notices just after the title page:

        Copyright (C)  YEAR  YOUR NAME.
        Permission is granted to copy, distribute and/or modify this document
        under the terms of the GNU Free Documentation License, Version 1.3
        or any later version published by the Free Software Foundation;
        with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
        A copy of the license is included in the section entitled "GNU
        Free Documentation License".

If you have Invariant Sections, Front-Cover Texts and Back-Cover
Texts, replace the "with … Texts." line with this:

        with the Invariant Sections being LIST THEIR TITLES, with the
        Front-Cover Texts being LIST, and with the Back-Cover Texts being LIST.

If you have Invariant Sections without Cover Texts, or some other
combination of the three, merge those two alternatives to suit the
situation.

If your document contains nontrivial examples of program code, we
recommend releasing these examples in parallel under your choice of
free software license, such as the GNU General Public License, to
permit their use in free software.
