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
      "x": 31.73,
      "y": 17.38,
      "w": 59.23,
      "h": 8.0,
      "k": 1.06,
      "dx": 0,
      "dy": 0,
      "radius": 16,
      "mx": 29.9,
      "my": 21.38,
      "lx": 28.0,
      "ly": 21.38,
      "anchor": "right"
    },
    {
      "n": 2,
      "id": "folder",
      "label": "Likely folder",
      "x": 14.42,
      "y": 32.0,
      "w": 16.35,
      "h": 5.23,
      "k": 1.05,
      "dx": 0,
      "dy": 0,
      "radius": 14,
      "mx": 11.6,
      "my": 34.6,
      "lx": 9.7,
      "ly": 34.6,
      "anchor": "right"
    },
    {
      "n": 3,
      "id": "menu",
      "label": "Menu bar icon",
      "x": 72.9,
      "y": 0,
      "w": 2.5,
      "h": 4.0,
      "k": 1.3,
      "dx": 0,
      "dy": 1.554,
      "radius": 10,
      "mx": 71.1,
      "my": 2.0,
      "lx": 69.2,
      "ly": 2.0,
      "anchor": "right"
    }
  ]
};
