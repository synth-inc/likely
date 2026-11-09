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
      "x": 35.622,
      "y": 14.889,
      "w": 54.547,
      "h": 8.959,
      "k": 1.06,
      "dx": 0,
      "dy": 0,
      "radius": 16,
      "mx": 32.65,
      "my": 19.37,
      "lx": 30.74,
      "ly": 19.37,
      "anchor": "right"
    },
    {
      "n": 2,
      "id": "folder",
      "label": "Likely folder",
      "x": 19.708,
      "y": 26.585,
      "w": 15.846,
      "h": 7.792,
      "k": 1.05,
      "dx": 0,
      "dy": 0,
      "radius": 14,
      "mx": 16.75,
      "my": 30.886,
      "lx": 14.84,
      "ly": 30.886,
      "anchor": "right"
    },
    {
      "n": 3,
      "id": "menu",
      "label": "Menu bar icon",
      "x": 72.073,
      "y": 0,
      "w": 4.339,
      "h": 4.079,
      "k": 1.3,
      "dx": 0,
      "dy": 1.554,
      "radius": 10,
      "mx": 67.76,
      "my": 2.1,
      "lx": 65.85,
      "ly": 2.1,
      "anchor": "right"
    }
  ]
};
