/* Likely "whole app" regions. All numbers are percent of the image:
   x, w, dx, mx, lx = % of image width; y, h, dy, my, ly = % of image height.
   x,y,w,h = source rectangle that pops out; k = pop-out scale; dx,dy = pop-out offset;
   mx,my = marker (number) center; lx,ly = label anchor point; anchor = which side of the label sits on (lx,ly). */
window.WA_CONFIG = {
  "version": 1,
  "regions": [
    {
      "n": 1,
      "id": "bar",
      "label": "Search bar",
      "x": 26.6,
      "y": 7.4,
      "w": 68.6,
      "h": 9.1,
      "k": 1.06,
      "dx": 0,
      "dy": 0,
      "radius": 16,
      "mx": 24.6,
      "my": 11.9,
      "lx": 22.7,
      "ly": 11.9,
      "anchor": "right"
    },
    {
      "n": 2,
      "id": "folder",
      "label": "Likely folder",
      "x": 6.6,
      "y": 24.4,
      "w": 18.6,
      "h": 5.8,
      "k": 1.05,
      "dx": 0,
      "dy": 0,
      "radius": 14,
      "mx": 27.4,
      "my": 27.3,
      "lx": 29.3,
      "ly": 27.3,
      "anchor": "left"
    },
    {
      "n": 3,
      "id": "menu",
      "label": "Menu bar icon",
      "x": 74.0,
      "y": 0,
      "w": 3.0,
      "h": 4.6,
      "k": 1.3,
      "dx": 0,
      "dy": 1.554,
      "radius": 10,
      "mx": 72.0,
      "my": 2.2,
      "lx": 70.1,
      "ly": 2.2,
      "anchor": "right"
    }
  ]
};
