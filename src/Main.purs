module Main where

import Prelude

import Control.Alt ((<|>))
import Control.Lazy (fix)
import Control.Monad.Gen (elements)
import Control.Promise (toAffE)
import Control.Promise as Control.Promise
import Data.Array (intercalate, length, replicate)
import Data.Array.NonEmpty (NonEmptyArray, cons', drop, fromNonEmpty, mapWithIndex, snoc, snoc', sortBy, take, toArray, uncons)
import Data.Array.NonEmpty as NEA
import Data.ArrayBuffer.ArrayBuffer (byteLength)
import Data.ArrayBuffer.DataView as DV
import Data.ArrayBuffer.Typed (class TypedArray, buffer, fromArray, set, setTyped, whole)
import Data.ArrayBuffer.Typed as Typed
import Data.ArrayBuffer.Types (ArrayView, Float32Array, Uint32Array)
import Data.Float32 (fromNumber')
import Data.Float32 as F
import Data.Function (on)
import Data.Int (ceil, floor, toNumber)
import Data.Int.Bits (complement, (.&.))
import Data.JSDate (getTime, now)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (class Newtype, unwrap)
import Data.NonEmpty (NonEmpty(..))
import Data.Traversable (sequence, sequence_, traverse)
import Data.Tuple (Tuple(..), snd)
import Data.UInt (fromInt)
import Debug (spy)
import Deku.Attribute ((!:=))
import Deku.Attributes (id_, klass_)
import Deku.Control (text, text_, (<#~>))
import Deku.DOM as D
import Deku.Toplevel (runInBody)
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay, error, launchAff_, throwError)
import Effect.Class (liftEffect)
import Effect.Class.Console (logShow)
import Effect.Random (random, randomInt)
import Effect.Ref as Ref
import FRP.Event (create)
import QualifiedDo.Alt as Alt
import Random.LCG (mkSeed)
import Record (union)
import Test.QuickCheck.Gen (Gen, evalGen)
import Unsafe.Coerce (unsafeCoerce)
import Web.DOM.Element (clientHeight, clientWidth)
import Web.GPU.BufferSource (fromUint32Array)
import Web.GPU.GPU (requestAdapter)
import Web.GPU.GPUAdapter (requestDevice)
import Web.GPU.GPUBindGroupEntry (GPUBufferBinding, gpuBindGroupEntry)
import Web.GPU.GPUBindGroupLayoutEntry (gpuBindGroupLayoutEntry)
import Web.GPU.GPUBuffer (GPUBuffer, getMappedRange, mapAsync, unmap)
import Web.GPU.GPUBufferBindingLayout (GPUBufferBindingLayout)
import Web.GPU.GPUBufferBindingType as GPUBufferBindingType
import Web.GPU.GPUBufferUsage (GPUBufferUsageFlags)
import Web.GPU.GPUBufferUsage as GPUBufferUsage
import Web.GPU.GPUCanvasAlphaMode (opaque)
import Web.GPU.GPUCanvasConfiguration (GPUCanvasConfiguration)
import Web.GPU.GPUCanvasContext (configure, getCurrentTexture)
import Web.GPU.GPUCommandEncoder (beginComputePass, copyBufferToBuffer, copyBufferToTexture, finish)
import Web.GPU.GPUComputePassEncoder as GPUComputePassEncoder
import Web.GPU.GPUDevice (GPUDevice, createBindGroup, createBindGroupLayout, createBuffer, createCommandEncoder, createComputePipeline, createPipelineLayout, createShaderModule, limits)
import Web.GPU.GPUDevice as GPUDevice
import Web.GPU.GPUExtent3D (gpuExtent3DWH)
import Web.GPU.GPUMapMode as GPUMapMode
import Web.GPU.GPUProgrammableStage (GPUProgrammableStage)
import Web.GPU.GPUQueue (onSubmittedWorkDone, submit, writeBuffer)
import Web.GPU.GPUShaderStage as GPUShaderStage
import Web.GPU.GPUTextureFormat as GPUTextureFormat
import Web.GPU.GPUTextureUsage as GPUTextureUsage
import Web.GPU.HTMLCanvasElement (getContext)
import Web.GPU.Internal.Bitwise ((.|.))
import Web.GPU.Internal.RequiredAndOptional (x)
import Web.GPU.Navigator (gpu)
import Web.HTML (HTMLCanvasElement, window)
import Web.HTML.HTMLCanvasElement (height, setHeight, setWidth, toElement, width)
import Web.HTML.Window (navigator, requestAnimationFrame)
import Web.Promise as Web.Promise

-- defs
inputData :: String
inputData =
  """
// input data
struct rendering_info_struct {
  real_canvas_width: u32, // width of the canvas in pixels
  overshot_canvas_width: u32, // width of the canvas in pixels so that the byte count per pixel is a multiple of 256
  canvas_height: u32, // height of the canvas in pixels
  n_spheres: u32, // number of spheres
  n_bvh_nodes: u32, // number of bvh_nodes
  anti_alias_passes: u32, // number of spheres
  current_time: f32 // current time in seconds
}
"""

aabb :: String
aabb =
  """

struct aabb {
  aabb_min: vec3<f32>,
  aabb_max: vec3<f32>
}

fn aabb_hit(bounds: ptr<function,aabb>, r: ptr<function,ray>, tmin: f32, tmax: f32) -> bool
{
  var a: u32 = 0;
  loop {
    if a >= 3 {
      break;
    }
    var invD = 1.0 / (*r).direction[a];
    var t0 = ((*bounds).aabb_min[a] - (*r).origin[a]) * invD;
    var t1 = ((*bounds).aabb_max[a] - (*r).origin[a]) * invD;
    if (invD < 0.0) {
      var tmp = t0;
      t0 = t1;
      t1 = tmp;
    }
    var bmin = select(tmin, t0, t0 > tmin); // t0 > tmin ? t0 : tmin;
    var bmax = select(tmax, t1, t1 < tmax); // t1 < tmax ? t1 : tmax;
    if (bmax <= bmin) {
      return false;
    }
    a++;
  }
  return true;
}
"""

bvhNode :: String
bvhNode =
  """
struct bvh_node {
  aabb_min_x: f32,
  aabb_min_y: f32,
  aabb_min_z: f32,
  aabb_max_x: f32,
  aabb_max_y: f32,
  aabb_max_z: f32,
  left: u32,
  right: u32,
  is_sphere: u32
}

fn bvh_node_bounding_box(node:bvh_node, box: ptr<function,aabb>) -> bool
{
  (*box).aabb_min = vec3<f32>((node).aabb_min_x, (node).aabb_min_y, (node).aabb_min_z);
  (*box).aabb_max = vec3<f32>((node).aabb_max_x, (node).aabb_max_y, (node).aabb_max_z);
  return true;
}

"""

newtype HitBVHInfo = HitBVHInfo
  { hitTName :: String
  , nodesName :: String
  , rName :: String
  , spheresName :: String
  , startNodeIx :: String
  , tMaxName :: String
  , tMinName :: String
  }

hitBVHNode :: HitBVHInfo -> String
hitBVHNode (HitBVHInfo { startNodeIx, nodesName, spheresName, rName, tMinName, tMaxName, hitTName }) = intercalate "\n"
  [ "  var bvh__namespaced__node_ix = " <> startNodeIx <> ";"
  , "  let bvh__namespaced__nodes = &" <> nodesName <> ";"
  , "  let bvh__namespaced__spheres = &" <> spheresName <> ";"
  , "  let bvh__namespaced__r = &" <> rName <> ";"
  , "  var bvh__namespaced__t_min = " <> tMinName <> ";"
  , "  var bvh__namespaced__t_max = " <> tMaxName <> ";"
  , "  let bvh__namespaced_t = &" <> hitTName <> ";"
  , """


  // we make our stack 100-deep, which is more than enough for our purposes
  var bvh__namespaced__on_left = array<bool, 100>();
  var bvh__namespaced__on_right = array<bool, 100>();
  var bvh__namespaced__sphere_left = array<u32, 100>();
  var bvh__namespaced__sphere_right = array<u32, 100>();
  var bvh__namespaced__hit_t_left = array<f32, 100>();
  var bvh__namespaced__hit_t_right = array<f32, 100>();
  var bvh__namespaced__parent_node = array<u32, 100>();

  var bvh__namespaced__tmp_box: aabb;
  var bvh__namespaced__stack = 0u;
  var bvh__return__hit = false;
  var bvh__return__ix = 0u;

  var debug_idx = 0u;
  var dbar_idx = 0u;
  var my_id = (rendering_info.canvas_height * rendering_info.real_canvas_width) - 444u;
  var dbg_cond = select(false, true, dbg_id == my_id);

  loop {
    debug_idx++;
    if (debug_idx > 1000u) { break; } // GUARD
    if (dbg_cond) { dbar_array[dbar_idx] = 0; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = debug_idx; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = 16; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__node_ix; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = 17; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = 18; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = u32(bvh__namespaced__on_left[bvh__namespaced__stack]); }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = 19; }
    dbar_idx++;
    if (dbg_cond) { dbar_array[dbar_idx] = u32(bvh__namespaced__on_right[bvh__namespaced__stack]); }
    dbar_idx++;
    ////////////////////
    ////////////////////
    // if bvh__namespaced__tmp_node is a sphere, we have a special flow and we short-circuit the left/right behavior
    if (((*bvh__namespaced__nodes)[bvh__namespaced__node_ix]).is_sphere == 1u) {
      var sphere_ix = ((*bvh__namespaced__nodes)[bvh__namespaced__node_ix]).left * 4u;
      var sphere_hit = hit_sphere(
        (*bvh__namespaced__spheres)[sphere_ix],
        (*bvh__namespaced__spheres)[sphere_ix+1],
        (*bvh__namespaced__spheres)[sphere_ix+2],
        (*bvh__namespaced__spheres)[sphere_ix+3],
        bvh__namespaced__r,
        bvh__namespaced__t_min,
        bvh__namespaced__t_max,
        bvh__namespaced_t);
      // in the unlikely event that our model has one sphere, we can short-circuit the rest of the logic
      if (bvh__namespaced__stack == 0u) {
        bvh__return__hit = sphere_hit;
        if (bvh__return__hit) {
          bvh__return__ix = sphere_ix / 4;
        }
        if (dbg_cond) { dbar_array[dbar_idx] = 1; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 42; }
        dbar_idx++;
        break;
      }
      // if so, report back a hit
      if (sphere_hit) {
        // increment by 1 to indicate a hit
        var i_plus_1 = ((*bvh__namespaced__nodes)[bvh__namespaced__node_ix]).left + 1u;
        if (bvh__namespaced__on_right[bvh__namespaced__stack - 1]) {
          bvh__namespaced__sphere_right[bvh__namespaced__stack - 1] = i_plus_1;
          bvh__namespaced__hit_t_right[bvh__namespaced__stack - 1] = *bvh__namespaced_t;
        } else {
          bvh__namespaced__sphere_left[bvh__namespaced__stack - 1] = i_plus_1;
          bvh__namespaced__hit_t_left[bvh__namespaced__stack - 1] = *bvh__namespaced_t;
        }
        if (dbg_cond) { dbar_array[dbar_idx] = 2; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = i_plus_1; }
        dbar_idx++;
      } else {
        // if not, report back a miss
        if (bvh__namespaced__on_right[bvh__namespaced__stack - 1]) {
          bvh__namespaced__sphere_right[bvh__namespaced__stack - 1] = 0;
          bvh__namespaced__hit_t_right[bvh__namespaced__stack - 1] = -1.0;
        } else {
          bvh__namespaced__sphere_left[bvh__namespaced__stack - 1] = 0;
          bvh__namespaced__hit_t_left[bvh__namespaced__stack - 1] = -1.0;
        }
        if (dbg_cond) { dbar_array[dbar_idx] = 3; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 666; }
        dbar_idx++;
      }
      // set the temp node back to the parent
      bvh__namespaced__node_ix = bvh__namespaced__parent_node[bvh__namespaced__stack];
      // decrease the counter
      bvh__namespaced__stack--;
      if (dbg_cond) { dbar_array[dbar_idx] = 4; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__node_ix; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = 5; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
      dbar_idx++;
      continue;
    }
    ////////////////////
    ////////////////////
    // we haven't yet started analyzing this box, attempt to fail fast
    if (!bvh__namespaced__on_left[bvh__namespaced__stack]) {
      // populate a bounding box with this node's information
      bvh_node_bounding_box((*bvh__namespaced__nodes)[bvh__namespaced__node_ix], &bvh__namespaced__tmp_box);
      if (aabb_hit(&bvh__namespaced__tmp_box, bvh__namespaced__r, bvh__namespaced__t_min, bvh__namespaced__t_max)) {
        // we dip into the left
        var left_ix = ((*bvh__namespaced__nodes)[bvh__namespaced__node_ix]).left;
        bvh__namespaced__on_left[bvh__namespaced__stack] = true;
        // increase the stack
        bvh__namespaced__stack++;
        // set the parent to this node index
        bvh__namespaced__parent_node[bvh__namespaced__stack] = bvh__namespaced__node_ix;
        // change the current node index now that the parent is set
        bvh__namespaced__node_ix = left_ix;
        if (dbg_cond) { dbar_array[dbar_idx] = 6; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__node_ix; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 7; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
        dbar_idx++;
        continue;
      } else { 
        // we have a miss
        if (bvh__namespaced__stack == 0u) {
          // we're done as there won't be a hit at this point
          if (dbg_cond) { dbar_array[dbar_idx] = 8; }
          dbar_idx++;
          if (dbg_cond) { dbar_array[dbar_idx] = 1024; }
          dbar_idx++;
          break;
        }
        // set the previous level's t to -1.0 as we missed
        if (bvh__namespaced__on_right[bvh__namespaced__stack-1u]) {
          bvh__namespaced__hit_t_right[bvh__namespaced__stack-1u] = -1.0;
        } else {
          bvh__namespaced__hit_t_left[bvh__namespaced__stack-1u] = -1.0;
        }
        // set the previous level's object to 0 as we missed
        if (bvh__namespaced__on_right[bvh__namespaced__stack-1u]) {
          bvh__namespaced__sphere_right[bvh__namespaced__stack-1u] = 0;
        } else {
          bvh__namespaced__sphere_left[bvh__namespaced__stack-1u] = 0;
        }
        // set the node index to the parent's index
        bvh__namespaced__node_ix = bvh__namespaced__parent_node[bvh__namespaced__stack];
        // decrease the stack
        bvh__namespaced__stack--;
        if (dbg_cond) { dbar_array[dbar_idx] = 9; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__node_ix; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 10; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
        dbar_idx++;
        continue;
      }
    }
    /////////////////
    /////////////////
    // we're at the end of a hit comparison
    if (bvh__namespaced__on_left[bvh__namespaced__stack] && bvh__namespaced__on_right[bvh__namespaced__stack]) {
      // take the min
      var min_t = select(
        select(
          select(bvh__namespaced__hit_t_right[bvh__namespaced__stack]
            , bvh__namespaced__hit_t_left[bvh__namespaced__stack]
            , bvh__namespaced__hit_t_left[bvh__namespaced__stack] < bvh__namespaced__hit_t_right[bvh__namespaced__stack])
            , bvh__namespaced__hit_t_left[bvh__namespaced__stack]
            , bvh__namespaced__hit_t_right[bvh__namespaced__stack] < 0.f
            )
          , bvh__namespaced__hit_t_right[bvh__namespaced__stack]
          , bvh__namespaced__hit_t_left[bvh__namespaced__stack] < 0.f);
      if (bvh__namespaced__stack == 0u) {
        if (min_t < 0.f) {
            // if both the mins are negative, then we have no hit, so the obj is 0
            bvh__return__hit = false;
        } else {
          // select the correct object, remembering to subtract 1 as 0 represents an unfound object
          bvh__return__ix = select(bvh__namespaced__sphere_left[0u]
            , bvh__namespaced__sphere_right[0u]
            , min_t == bvh__namespaced__hit_t_right[0u]) - 1; 
          bvh__return__hit = true;
          *bvh__namespaced_t = min_t;
        }
        if (dbg_cond) { dbar_array[dbar_idx] = 11; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 777; }
        dbar_idx++;
        // we're done!
        break;
      } else {
        if (bvh__namespaced__on_right[bvh__namespaced__stack-1u]) {
          bvh__namespaced__hit_t_right[bvh__namespaced__stack-1u] = min_t;
        } else {
          bvh__namespaced__hit_t_left[bvh__namespaced__stack-1u] = min_t;
        }
        // no need to add or subtract 1 to sphere index as we are just passing it through
        var sphere_ix = select(bvh__namespaced__sphere_left[bvh__namespaced__stack]
            , bvh__namespaced__sphere_right[bvh__namespaced__stack]
            , min_t == bvh__namespaced__hit_t_right[bvh__namespaced__stack]);
        if (bvh__namespaced__on_right[bvh__namespaced__stack-1u]) {
          bvh__namespaced__sphere_right[bvh__namespaced__stack-1u] = sphere_ix;
        } else {
          bvh__namespaced__sphere_left[bvh__namespaced__stack-1u] = sphere_ix;
        }
        // mark both bools on this level as false
        if (dbg_cond) { dbar_array[dbar_idx] = 22; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 24242; }
        dbar_idx++;
        bvh__namespaced__on_left[bvh__namespaced__stack] = false;
        bvh__namespaced__on_right[bvh__namespaced__stack] = false;
        // set the node ix to the parent
        bvh__namespaced__node_ix = bvh__namespaced__parent_node[bvh__namespaced__stack];
        // decrease the stack
        bvh__namespaced__stack--;
        if (dbg_cond) { dbar_array[dbar_idx] = 12; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__node_ix; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = 13; }
        dbar_idx++;
        if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
        dbar_idx++;
      }
      continue;
    }
    ///////////////// 
    /////////////////
    if (bvh__namespaced__on_left[bvh__namespaced__stack]) {
      // we dip into the right
      var right_ix = ((*bvh__namespaced__nodes)[bvh__namespaced__node_ix]).right;
      bvh__namespaced__on_right[bvh__namespaced__stack] = true;
      if (dbg_cond) { dbar_array[dbar_idx] = 20; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = 21; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = u32(bvh__namespaced__on_right[bvh__namespaced__stack]); }
      dbar_idx++;
      // increase the stack
      bvh__namespaced__stack++;
      // set the parent to this node index
      bvh__namespaced__parent_node[bvh__namespaced__stack] = bvh__namespaced__node_ix;
      // change the current node index now that the parent is set
      bvh__namespaced__node_ix = right_ix;
      if (dbg_cond) { dbar_array[dbar_idx] = 14; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__node_ix; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = 15; }
      dbar_idx++;
      if (dbg_cond) { dbar_array[dbar_idx] = bvh__namespaced__stack; }
      dbar_idx++;
      continue;
    }
    /////////////////
    /////////////////
    // panic!
    // should never get here
    break; // out of safety, but we really should never get here
  }
"""
  ]

sphereBoundingBox :: String
sphereBoundingBox =
  """
fn sphere_bounding_box(cx: f32, cy: f32, cz: f32, radius: f32, box: ptr<function,aabb>) -> bool
{
  var center = vec3(cx, cy, cz);
  (*box).aabb_min = center - vec3(radius, radius, radius);
  (*box).aabb_max = center + vec3(radius, radius, radius);
  return true;
}
  """

antiAliasFuzzing :: String
antiAliasFuzzing =
  """
const fuzz_fac = 0.5;
const half_fuzz_fac = fuzz_fac / 2.0;
fn fuzz2(i: u32, n: u32, d: u32) -> f32
{
    var fi = f32(i);
    return fi; // + (fuzz_fac * pow(f32(n) / f32(d), 0.5) - half_fuzz_fac);
}
"""

lerp :: String
lerp =
  """
// lerp
fn lerp(a: f32, b: f32, t: f32) -> f32 {
  return a + (b - a) * t;
}
"""

lerpv :: String
lerpv =
  """
// lerpv
fn lerpv(a: ptr<function,vec3<f32>>, b: ptr<function,vec3<f32>>, t: f32) -> vec3<f32> {
  return (*a) + ((*b) - (*a)) * t;
}
"""

ray :: String
ray =
  """// ray
struct ray {
  origin: vec3<f32>,
  direction: vec3<f32>
}
"""

hitRecord :: String
hitRecord =
  """
// hit record
struct hit_record {
  t: f32,
  p: vec3<f32>,
  normal: vec3<f32>
}

      """

pointAtParameter :: String
pointAtParameter =
  """
// point at parameter
fn point_at_parameter(r: ptr<function,ray>, t: f32) -> vec3<f32> {
  return (*r).origin + t * (*r).direction;
}"""

hitSphere :: String
hitSphere =
  """
// hit sphere
fn hit_sphere(cx: f32, cy: f32, cz: f32, radius: f32, r: ptr<function,ray>, t_min: f32, t_max: f32, hit_t: ptr<function,f32>) -> bool {
  var center = vec3(cx, cy, cz);
  var oc = (*r).origin - center;
  var a = dot((*r).direction, (*r).direction);
  var b = dot(oc, (*r).direction);
  var c = dot(oc, oc) - radius * radius;
  var discriminant = b * b - a * c;
  if (discriminant > 0) {
    var temp = (-b - sqrt(discriminant)) / a;
    if (temp < t_max && temp > t_min) {
      *hit_t = temp;
      return true;
    }
    temp = (-b + sqrt(discriminant)) / a;
    if (temp < t_max && temp > t_min) {
      *hit_t = temp;
      return true;
    }
  }
  return false;
}
"""

makeHitRec :: String
makeHitRec =
  """
// make hit rec
fn make_hit_rec(cx: f32, cy: f32, cz: f32, radius: f32, t: f32, r: ptr<function,ray>, rec: ptr<function,hit_record>) -> bool {
  (*rec).t = t;
  (*rec).p = point_at_parameter(r, t);
  (*rec).normal = ((*rec).p - vec3(cx,cy,cz)) / radius;
  return true;
}

"""

usefulConsts :: String
usefulConsts =
  """
const color_mult = 1 << 8;
const origin = vec3(0.0, 0.0, 0.0);
      """

type NodeBounds =
  ( aabb_min_x :: Number
  , aabb_min_y :: Number
  , aabb_min_z :: Number
  , aabb_max_x :: Number
  , aabb_max_y :: Number
  , aabb_max_z :: Number
  )

newtype BVHNode = BVHNode
  { left :: Int
  , right :: Int
  , is_sphere :: Int
  | NodeBounds
  }

derive instance Newtype BVHNode _
derive newtype instance Show BVHNode

type Sphere' =
  { cx :: Number
  , cy :: Number
  , cz :: Number
  , radius :: Number
  }

newtype Sphere = Sphere Sphere'

derive instance Newtype Sphere _
derive newtype instance Show Sphere

data Axis = XAxis | YAxis | ZAxis

spheresToFlatRep :: NonEmptyArray Sphere -> Array Number
spheresToFlatRep arr = join $ toArray $ map (\(Sphere { cx, cy, cz, radius }) -> [ cx, cy, cz, radius ]) arr

spheresToBVHNodes :: Int -> NonEmptyArray Sphere -> NonEmptyArray BVHNode
spheresToBVHNodes seed arr = (evalGen (go [] (mapWithIndex Tuple arr)) { newSeed: mkSeed seed, size: 10 }).array
  where
  go
    :: Array BVHNode
    -> NonEmptyArray (Tuple Int Sphere)
    -> Gen
         { array :: NonEmptyArray BVHNode
         , index :: Int
         , n :: BVHNode
         }
  go bvhs spheres = do
    let { head, tail } = uncons spheres
    case tail of
      [] -> do
        let Tuple i (Sphere a) = head
        let
          n = BVHNode
            { aabb_min_x: a.cx - a.radius
            , aabb_min_y: a.cy - a.radius
            , aabb_min_z: a.cz - a.radius
            , aabb_max_x: a.cx + a.radius
            , aabb_max_y: a.cy + a.radius
            , aabb_max_z: a.cz + a.radius
            , left: i
            , right: 0
            , is_sphere: 1
            }
        pure
          { array: snoc' bvhs n
          , index: length bvhs
          , n
          }
      _ -> do
        i <- elements (fromNonEmpty $ NonEmpty XAxis [ YAxis, ZAxis ])
        let sorted = sortAlong i spheres
        -- we have proof that this is at least 2, so we can use unsafeCoerce
        let l = take (NEA.length sorted / 2) sorted
        let r = drop (NEA.length sorted / 2) sorted
        { array: bvhsL, index: leftIndex, n: nl } <- go bvhs ((unsafeCoerce :: Array ~> NonEmptyArray) l)
        { array: bvhsR, index: rightIndex, n: nr } <- go (toArray bvhsL) ((unsafeCoerce :: Array ~> NonEmptyArray) r)
        let sb = surroundingBox nl nr
        let
          n = BVHNode
            ( sb `union`
                { left: leftIndex
                , right: rightIndex
                , is_sphere: 0
                }
            )
        pure
          { array: snoc bvhsR n
          , index: NEA.length bvhsR
          , n
          }

  surroundingBox :: BVHNode -> BVHNode -> { | NodeBounds }
  surroundingBox (BVHNode box0) (BVHNode box1) =
    { aabb_min_x: min box0.aabb_min_x box1.aabb_min_x
    , aabb_min_y: min box0.aabb_min_y box1.aabb_min_y
    , aabb_min_z: min box0.aabb_min_z box1.aabb_min_z
    , aabb_max_x: max box0.aabb_max_x box1.aabb_max_x
    , aabb_max_y: max box0.aabb_max_y box1.aabb_max_y
    , aabb_max_z: max box0.aabb_max_z box1.aabb_max_z
    }

  cf :: (Sphere' -> Number) -> Tuple Int Sphere -> Tuple Int Sphere -> Ordering
  cf f = (compare `on` (snd >>> unwrap >>> f))

  sortAlong :: Axis -> NonEmptyArray (Tuple Int Sphere) -> NonEmptyArray (Tuple Int Sphere)
  sortAlong axis iarr = case axis of
    XAxis -> sortBy (cf _.cx) iarr
    YAxis -> sortBy (cf _.cy) iarr
    ZAxis -> sortBy (cf _.cz) iarr

averager :: forall a. EuclideanRing a => Effect (a -> Effect a)
averager = do
  ct <- Ref.new zero
  val <- Ref.new zero
  pure \v -> do
    ct' <- Ref.read ct
    val' <- Ref.read val
    Ref.write (ct' + one) ct
    Ref.write (val' + v) val
    pure $ val' / ct'

convertPromise :: Web.Promise.Promise ~> Control.Promise.Promise
convertPromise = unsafeCoerce

type FrameInfo = { avgFrame :: Number, avgTime :: Number }

createBufferF
  :: forall a t
   . TypedArray a t
  => GPUDevice
  -> ArrayView a
  -> GPUBufferUsageFlags
  -> Effect GPUBuffer
createBufferF device arr usage = do
  let
    desc = x
      { size: ((byteLength (buffer arr)) + 3) .&. complement 3
      , usage
      , mappedAtCreation: true
      }
  buffer <- createBuffer device desc
  writeArray <- getMappedRange buffer >>= whole
  _ <- setTyped writeArray Nothing arr
  unmap buffer
  pure buffer

bvhNodesToFloat32Array :: NonEmptyArray BVHNode -> Effect Float32Array
bvhNodesToFloat32Array arr = do
  flar <- join <$> traverse go (toArray arr)
  fromArray flar
  where
  go :: BVHNode -> Effect (Array F.Float32)
  go
    ( BVHNode
        { aabb_min_x
        , aabb_min_y
        , aabb_min_z
        , aabb_max_x
        , aabb_max_y
        , aabb_max_z
        , left
        , right
        , is_sphere
        }
    ) = do
    tl :: Uint32Array <- fromArray [ fromInt left, fromInt right, fromInt is_sphere ]
    tlv :: Array F.Float32 <- (whole :: _ -> Effect Float32Array) (DV.buffer (DV.whole (Typed.buffer tl))) >>= Typed.toArray
    pure $
      [ fromNumber' aabb_min_x
      , fromNumber' aabb_min_y
      , fromNumber' aabb_min_z
      , fromNumber' aabb_max_x
      , fromNumber' aabb_max_y
      , fromNumber' aabb_max_z
      ] <> tlv

gpuMe :: Effect Unit -> (FrameInfo -> Effect Unit) -> HTMLCanvasElement -> Effect Unit
gpuMe showErrorMessage pushFrameInfo canvas = launchAff_ $ delay (Milliseconds 20.0) *> liftEffect do
  context <- getContext canvas >>= maybe
    (showErrorMessage *> throwError (error "could not find context"))
    pure
  timeDeltaAverager <- averager
  frameDeltaAverager <- averager
  startsAt <- getTime <$> now
  currentFrame <- Ref.new 0
  entry <- window >>= navigator >>= gpu >>= case _ of
    Nothing -> do
      showErrorMessage
      throwError $ error "WebGPU is not supported"
    Just entry -> pure entry
  launchAff_ do
    adapter <- (toAffE $ convertPromise <$> requestAdapter entry (x {})) >>=
      case _ of
        Nothing -> liftEffect do
          showErrorMessage
          throwError $ error "WebGPU is not supported"
        Just adapter -> pure adapter
    device <- (toAffE $ convertPromise <$> requestDevice adapter (x {})) >>=
      case _ of
        Nothing -> liftEffect do
          showErrorMessage
          throwError $ error "WebGPU is not supported"
        Just device -> pure device
    queue <- liftEffect $ GPUDevice.queue device
    deviceLimits <- liftEffect $ limits device
    canvasInfoBuffer <- liftEffect $ createBuffer device $ x
      { size: 28 -- align(4) size(28)
      , usage: GPUBufferUsage.copyDst .|. GPUBufferUsage.storage
      }
    debugBuffer <- liftEffect $ createBuffer device $ x
      { size: 65536
      , usage: GPUBufferUsage.copySrc .|. GPUBufferUsage.storage
      }
    debugOutputBuffer <- liftEffect $ createBuffer device $ x
      { size: 65536
      , usage: GPUBufferUsage.copyDst .|. GPUBufferUsage.mapRead
      }
    seed <- liftEffect $ randomInt 42 42424242
    randos <- liftEffect $ sequence_ $ replicate 100 $ Sphere <$> ({ cx: _, cy: 0.25, cz: _, radius: 0.125 } <$> (random <#> \n -> n * 4.0 - 2.0) <*> (random <#> \n -> n * 4.0 - 2.0))
    let
      spheres =
        cons' (Sphere { cx: 0.0, cy: 0.0, cz: -1.0, radius: 0.5 })
          [ Sphere { cx: 0.0, cy: -100.5, cz: -1.0, radius: 100.0 }
          ]
      bvhNodes = spheresToBVHNodes seed spheres
      rawSphereData = map fromNumber' (spheresToFlatRep spheres)
    logShow bvhNodes
    logShow spheres
    bvhNodeData <- liftEffect $ bvhNodesToFloat32Array bvhNodes
    let nSpheres = NEA.length spheres
    let nBVHNodes = NEA.length bvhNodes
    sphereData :: Float32Array <- liftEffect $ fromArray rawSphereData
    sphereBuffer <- liftEffect $ createBufferF device sphereData GPUBufferUsage.storage
    bvhNodeBuffer <- liftEffect $ createBufferF device bvhNodeData GPUBufferUsage.storage
    rawColorBuffer <- liftEffect $ createBuffer device $ x
      { size: deviceLimits.maxStorageBufferBindingSize
      , usage: GPUBufferUsage.storage
      }
    hitsBuffer <- liftEffect $ createBuffer device $ x
      { size: deviceLimits.maxStorageBufferBindingSize
      , usage: GPUBufferUsage.storage
      }
    wholeCanvasBuffer <- liftEffect $ createBuffer device $ x
      { size: deviceLimits.maxStorageBufferBindingSize
      , usage: GPUBufferUsage.copySrc .|. GPUBufferUsage.storage
      }
    let
      clearBufferDesc = x
        { code:
            intercalate "\n"
              [ inputData
              , """
// main
@group(0) @binding(0) var<storage, read> rendering_info : rendering_info_struct;
@group(1) @binding(0) var<storage, read_write> result_array : array<u32>;
@compute @workgroup_size(16, 16, 1)
fn main(@builtin(global_invocation_id) global_id : vec3<u32>) {
  // assume that x is always w, y is always h
  // but z is variable
  result_array[global_id.z * rendering_info.real_canvas_width * rendering_info.canvas_height + global_id.y * rendering_info.real_canvas_width + global_id.x] = 0u;
}"""
              ]
        }
    clearBufferModule <- liftEffect $ createShaderModule device clearBufferDesc
    let
      (clearBufferStage :: GPUProgrammableStage) = x
        { "module": clearBufferModule
        , entryPoint: "main"
        }
    let
      hitDesc = x
        { code: spy "hitDesc" $ intercalate "\n"
            [ lerp
            , lerpv
            , inputData
            , ray
            , antiAliasFuzzing
            , pointAtParameter
            , hitSphere
            , aabb
            , bvhNode
            , sphereBoundingBox
            , usefulConsts
            , """
// main
@group(0) @binding(0) var<storage, read> rendering_info : rendering_info_struct;
@group(0) @binding(1) var<storage, read> sphere_info : array<f32>;
@group(0) @binding(2) var<storage, read> bvh_info : array<bvh_node>;
@group(1) @binding(0) var<storage, read_write> result_array : array<u32>;
@group(2) @binding(0) var<storage, read_write> dbar_array : array<u32>;
@compute @workgroup_size(16, 16, 1)
fn main(@builtin(global_invocation_id) global_id : vec3<u32>) {
  if (global_id.x >= rendering_info.real_canvas_width  || global_id.y >= rendering_info.canvas_height || global_id.z >  rendering_info.anti_alias_passes) {
    return;
  }
  var dbg_id = global_id.y * rendering_info.real_canvas_width + global_id.x;
  var cwch = rendering_info.real_canvas_width * rendering_info.canvas_height;
  var aspect = f32(rendering_info.real_canvas_width) / f32(rendering_info.canvas_height);
  var ambitus_x = select(2.0 * aspect, 2.0, aspect < 1.0);
  var ambitus_y = select(2.0 * aspect, 2.0, aspect >= 1.0);
  var lower_left_corner = vec3(-ambitus_x / 2.0, -ambitus_y / 2.0, -1.0);
  var alias_pass = global_id.z;
  var p_x = fuzz2(global_id.x, alias_pass, rendering_info.anti_alias_passes) / f32(rendering_info.real_canvas_width);
  var p_y = 1. - fuzz2(global_id.y, alias_pass, rendering_info.anti_alias_passes) / f32(rendering_info.canvas_height);
  var r: ray;
  r.origin = origin;
  r.direction = lower_left_corner + vec3(p_x * ambitus_x, p_y * ambitus_y, 0.0);
  var hit_t: f32 = 0.42424242424242;
  """
            , hitBVHNode
                ( HitBVHInfo
                    { startNodeIx: "rendering_info.n_bvh_nodes - 1"
                    , nodesName: "bvh_info"
                    , spheresName: "sphere_info"
                    , rName: "r"
                    , tMinName: "0.0001"
                    , tMaxName: "1000.f"
                    , hitTName: "hit_t"
                    }
                )
            , """ 
  if (bvh__return__hit) {
    var sphere_idx = f32(bvh__return__ix);
    var idx = (global_id.y * rendering_info.real_canvas_width + global_id.x) + (cwch * global_id.z);
    result_array[idx] = pack2x16float(vec2<f32>(sphere_idx, hit_t));
  }
}"""
            ]
        }
    hitModule <- liftEffect $ createShaderModule device hitDesc
    let
      (hitStage :: GPUProgrammableStage) = x
        { "module": hitModule
        , entryPoint: "main"
        }
    let
      colorFillDesc = x
        { code:
            intercalate "\n"
              [ lerp
              , lerpv
              , inputData
              , ray
              , antiAliasFuzzing
              , pointAtParameter
              , hitRecord
              , makeHitRec
              , usefulConsts
              , """
// color
fn hit_color(r: ptr<function,ray>, rec: ptr<function,hit_record>) -> vec3<f32> {
  var normal = (*rec).normal;
  return 0.5 * vec3<f32>(normal.x + 1.0, normal.y + 1.0, normal.z + 1.0);
}

fn sky_color(r: ptr<function,ray>) -> vec3<f32> {
  var unit_direction = normalize((*r).direction);
  var t = 0.5 * (unit_direction.y + 1.0);
  var white = vec3<f32>(1.0, 1.0, 1.0);
  var sky_blue = vec3<f32>(0.5, 0.7, 1.0);
  return lerpv(&white, &sky_blue, t);
}

// main
@group(0) @binding(0) var<storage, read> rendering_info : rendering_info_struct;
@group(0) @binding(1) var<storage, read> sphere_info : array<f32>;
@group(1) @binding(0) var<storage, read> hit_info : array<u32>;
@group(2) @binding(0) var<storage, read_write> result_array : array<atomic<u32>>;
@compute @workgroup_size(16, 16, 1)
fn main(@builtin(global_invocation_id) global_id : vec3<u32>) {
  if (global_id.x >= rendering_info.real_canvas_width  || global_id.y >= rendering_info.canvas_height || global_id.z >= rendering_info.anti_alias_passes) {
    return;
  }
  var cwch = rendering_info.real_canvas_width * rendering_info.canvas_height;
  var aspect = f32(rendering_info.real_canvas_width) / f32(rendering_info.canvas_height);
  var ambitus_x = select(2.0 * aspect, 2.0, aspect < 1.0);
  var ambitus_y = select(2.0 * aspect, 2.0, aspect >= 1.0);
  var lower_left_corner = vec3(-ambitus_x / 2.0, -ambitus_y / 2.0, -1.0);
  var alias_pass = global_id.z;
  var p_x = fuzz2(global_id.x, alias_pass, rendering_info.anti_alias_passes) / f32(rendering_info.real_canvas_width);
  var p_y = 1. - fuzz2(global_id.y, alias_pass, rendering_info.anti_alias_passes) / f32(rendering_info.canvas_height);
  var r: ray;
  r.origin = origin;
  r.direction = lower_left_corner + vec3(p_x * ambitus_x, p_y * ambitus_y, 0.0);
  var hit_idx = (global_id.y * rendering_info.real_canvas_width + global_id.x) + (cwch * global_id.z);
  var was_i_hit = hit_info[hit_idx];
  var my_color = vec3(0.0,0.0,0.0);
  // my_color = sky_color(&r);
  if (was_i_hit == 0u) {
    my_color = sky_color(&r);
  } else {
    var unpacked = unpack2x16float(was_i_hit);
    var sphere_idx = u32(unpacked[0]);
    var sphere_offset = sphere_idx * 4;
    var norm_t = unpacked[1];
    var rec: hit_record;
    _ = make_hit_rec(sphere_info[sphere_offset], sphere_info[sphere_offset + 1], sphere_info[sphere_offset + 2], sphere_info[sphere_offset + 3], norm_t, &r, &rec);
    my_color = hit_color(&r, &rec);
  }
  var idx = (global_id.y * rendering_info.real_canvas_width + global_id.x) * 3;
  _ = atomicAdd(&result_array[idx], u32(my_color.b * color_mult));
  _ = atomicAdd(&result_array[idx + 1],  u32(my_color.g * color_mult));
  _ = atomicAdd(&result_array[idx + 2], u32(my_color.r * color_mult));
}
"""
              ]
        }
    colorFillModule <- liftEffect $ createShaderModule device colorFillDesc
    let
      (colorFillStage :: GPUProgrammableStage) = x
        { "module": colorFillModule
        , entryPoint: "main"
        }
    let
      antiAliasDesc = x
        { code:
            intercalate "\n"
              [ lerp
              , lerpv
              , inputData
              , ray
              , antiAliasFuzzing
              , pointAtParameter
              , hitRecord
              , makeHitRec
              , usefulConsts
              , """
// average the anti-aliasing
fn cc(c: u32, aap: u32) -> f32 {
  return max(0.0, min(1.0, f32(c) / f32(color_mult * aap)));
}
// main
@group(0) @binding(0) var<storage, read> rendering_info : rendering_info_struct;
@group(0) @binding(1) var<storage, read> sphere_info : array<f32>;
@group(1) @binding(0) var<storage, read> color_info : array<u32>;
@group(2) @binding(0) var<storage, read_write> result_array : array<u32>;
@compute @workgroup_size(16, 16, 1)
fn main(@builtin(global_invocation_id) global_id : vec3<u32>) {
  if (global_id.x >= rendering_info.real_canvas_width  || global_id.y >= rendering_info.canvas_height) {
    return;
  }
  var idx = (global_id.y * rendering_info.real_canvas_width + global_id.x) * 3;
  var overshot_idx = global_id.x + (global_id.y * rendering_info.overshot_canvas_width);
  result_array[overshot_idx] = pack4x8unorm(vec4(cc(color_info[idx], rendering_info.anti_alias_passes), cc(color_info[idx + 1], rendering_info.anti_alias_passes), cc(color_info[idx + 2], rendering_info.anti_alias_passes), 1.f));
}
"""
              ]
        }
    antiAliasModule <- liftEffect $ createShaderModule device antiAliasDesc
    let
      (antiAliasStage :: GPUProgrammableStage) = x
        { "module": antiAliasModule
        , entryPoint: "main"
        }
    readerBindGroupLayout <- liftEffect $ createBindGroupLayout device
      $ x
          { entries:
              [
                -- info about the current scene
                gpuBindGroupLayoutEntry 0 GPUShaderStage.compute
                  ( x { type: GPUBufferBindingType.readOnlyStorage }
                      :: GPUBufferBindingLayout
                  )
              -- spheres
              , gpuBindGroupLayoutEntry 1 GPUShaderStage.compute
                  ( x { type: GPUBufferBindingType.readOnlyStorage }
                      :: GPUBufferBindingLayout
                  )
              -- bounding boxes
              , gpuBindGroupLayoutEntry 2 GPUShaderStage.compute
                  ( x { type: GPUBufferBindingType.readOnlyStorage }
                      :: GPUBufferBindingLayout
                  )
              ]
          }
    rBindGroupLayout <- liftEffect $ createBindGroupLayout device
      $ x
          { entries:
              [ gpuBindGroupLayoutEntry 0 GPUShaderStage.compute
                  ( x { type: GPUBufferBindingType.readOnlyStorage }
                      :: GPUBufferBindingLayout
                  )
              ]
          }
    wBindGroupLayout <- liftEffect $ createBindGroupLayout device
      $ x
          { entries:
              [ gpuBindGroupLayoutEntry 0 GPUShaderStage.compute
                  ( x { type: GPUBufferBindingType.storage }
                      :: GPUBufferBindingLayout
                  )
              ]
          }
    let debugBindGroupLayout = wBindGroupLayout
    -- for when we are reading from a context and writing to a buffer
    readOPipelineLayout <- liftEffect $ createPipelineLayout device $ x
      { bindGroupLayouts: [ readerBindGroupLayout, wBindGroupLayout ] }
    readODebugPipelineLayout <- liftEffect $ createPipelineLayout device $ x
      { bindGroupLayouts: [ readerBindGroupLayout, wBindGroupLayout, debugBindGroupLayout ] }
    -- for when we are reading from a context, taking an input, and transforming it
    -- to an output
    readIOPipelineLayout <- liftEffect $ createPipelineLayout device $ x
      { bindGroupLayouts: [ readerBindGroupLayout, rBindGroupLayout, wBindGroupLayout ] }
    readerBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: readerBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: canvasInfoBuffer } :: GPUBufferBinding)
          , gpuBindGroupEntry 1
              (x { buffer: sphereBuffer } :: GPUBufferBinding)
          , gpuBindGroupEntry 2
              (x { buffer: bvhNodeBuffer } :: GPUBufferBinding)
          ]
      }
    wHitsBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: wBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: hitsBuffer } :: GPUBufferBinding)
          ]
      }
    rHitsBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: rBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: hitsBuffer } :: GPUBufferBinding)
          ]
      }
    wColorsBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: wBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: rawColorBuffer } :: GPUBufferBinding)
          ]
      }
    rColorsBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: rBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: rawColorBuffer } :: GPUBufferBinding)
          ]
      }
    wCanvasBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: wBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: wholeCanvasBuffer } :: GPUBufferBinding)
          ]
      }
    debugBindGroup <- liftEffect $ createBindGroup device $ x
      { layout: debugBindGroupLayout
      , entries:
          [ gpuBindGroupEntry 0
              (x { buffer: debugBuffer } :: GPUBufferBinding)
          ]
      }
    clearBufferPipeline <- liftEffect $ createComputePipeline device $ x
      { layout: readOPipelineLayout
      , compute: clearBufferStage
      }
    hitComputePipeline <- liftEffect $ createComputePipeline device $ x
      { layout: readODebugPipelineLayout
      , compute: hitStage
      }
    colorFillComputePipeline <- liftEffect $ createComputePipeline device $ x
      { layout: readIOPipelineLayout
      , compute: colorFillStage
      }
    antiAliasComputePipeline <- liftEffect $ createComputePipeline device $ x
      { layout: readIOPipelineLayout
      , compute: antiAliasStage
      }

    let
      (config :: GPUCanvasConfiguration) = x
        { device
        , format: GPUTextureFormat.bgra8unorm
        , usage:
            GPUTextureUsage.renderAttachment .|. GPUTextureUsage.copyDst
        , alphaMode: opaque
        }
    liftEffect $ configure context config
    loopN <- liftEffect $ Ref.new 0
    let maxStorageBufferBindingSize = deviceLimits.maxStorageBufferBindingSize
    let
      encodeCommands colorTexture = do
        whichLoop <- Ref.modify (_ + 1) loopN
        canvasWidth <- width canvas
        canvasHeight <- height canvas
        let bufferWidth = ceil (toNumber canvasWidth * 4.0 / 256.0) * 256
        let overshotWidth = bufferWidth / 4
        let antiAliasPasses = 1 -- min 16 $ floor (toNumber maxStorageBufferBindingSize / (toNumber (canvasWidth * canvasHeight * nSpheres * 4)))
        -- logShow antiAliasPasses
        tn <- (getTime >>> (_ - startsAt) >>> (_ * 0.001)) <$> now
        cf <- Ref.read currentFrame
        Ref.write (cf + 1) currentFrame
        commandEncoder <- createCommandEncoder device (x {})
        let workgroupX = ceil (toNumber canvasWidth / 16.0)
        let workgroupY = ceil (toNumber canvasHeight / 16.0)
        cinfo <- fromArray $ map fromInt
          [ canvasWidth
          , overshotWidth
          , canvasHeight
          , nSpheres
          , nBVHNodes
          , antiAliasPasses
          , 0
          ]
        let asBuffer = buffer cinfo
        whole asBuffer >>= \(x :: Float32Array) -> void $ set x (Just 6) [ fromNumber' tn ]
        writeBuffer queue canvasInfoBuffer 0 (fromUint32Array cinfo)
        -- not necessary in the loop, but useful as a stress test for animating positions
        computePassEncoder <- beginComputePass commandEncoder (x {})
        -- clear spheres as they're subject to an atomic operation
        GPUComputePassEncoder.setPipeline computePassEncoder clearBufferPipeline
        GPUComputePassEncoder.setBindGroup computePassEncoder 0
          readerBindGroup
        GPUComputePassEncoder.setBindGroup computePassEncoder 1
          wHitsBindGroup
        GPUComputePassEncoder.dispatchWorkgroupsXYZ computePassEncoder workgroupX workgroupY 1
        -- clear colors as they're subject to an atomic operation
        GPUComputePassEncoder.setBindGroup computePassEncoder 1
          wColorsBindGroup
        GPUComputePassEncoder.dispatchWorkgroupsXYZ computePassEncoder workgroupX workgroupY 3
        -- get hits
        GPUComputePassEncoder.setBindGroup computePassEncoder 1
          wHitsBindGroup
        GPUComputePassEncoder.setBindGroup computePassEncoder 2
          debugBindGroup
        GPUComputePassEncoder.setPipeline computePassEncoder
          hitComputePipeline
        GPUComputePassEncoder.dispatchWorkgroupsXYZ computePassEncoder workgroupX workgroupY antiAliasPasses
        -- colorFill
        GPUComputePassEncoder.setBindGroup computePassEncoder 1
          rHitsBindGroup
        GPUComputePassEncoder.setBindGroup computePassEncoder 2
          wColorsBindGroup
        GPUComputePassEncoder.setPipeline computePassEncoder
          colorFillComputePipeline
        GPUComputePassEncoder.dispatchWorkgroupsXYZ computePassEncoder workgroupX workgroupY antiAliasPasses
        -- antiAlias
        GPUComputePassEncoder.setBindGroup computePassEncoder 1
          rColorsBindGroup
        GPUComputePassEncoder.setBindGroup computePassEncoder 2
          wCanvasBindGroup
        GPUComputePassEncoder.setPipeline computePassEncoder
          antiAliasComputePipeline
        GPUComputePassEncoder.dispatchWorkgroupsXYZ computePassEncoder workgroupX workgroupY 1

        --
        GPUComputePassEncoder.end computePassEncoder
        copyBufferToTexture
          commandEncoder
          (x { buffer: wholeCanvasBuffer, bytesPerRow: bufferWidth })
          (x { texture: colorTexture })
          (gpuExtent3DWH canvasWidth canvasHeight)
        copyBufferToBuffer commandEncoder debugBuffer 0 debugOutputBuffer 0 65536
        toSubmit <- finish commandEncoder
        submit queue [ toSubmit ]
        launchAff_ do
          toAffE $ convertPromise <$> if whichLoop == 100 then mapAsync debugOutputBuffer GPUMapMode.read else onSubmittedWorkDone queue
          liftEffect do
            when (whichLoop == 100) do
              bfr <- getMappedRange debugOutputBuffer
              buffy <- (Typed.whole bfr :: Effect Uint32Array) >>= Typed.toArray
              let _ = spy "buffy" buffy
              unmap debugOutputBuffer
            tnx <- (getTime >>> (_ - startsAt) >>> (_ * 0.001)) <$> now
            cfx <- Ref.read currentFrame
            avgTime <- timeDeltaAverager (tnx - tn)
            avgFrame <- frameDeltaAverager (toNumber (cfx - cf))
            pushFrameInfo { avgTime, avgFrame }
    let
      render = unit # fix \f _ -> do
        cw <- clientWidth (toElement canvas)
        ch <- clientHeight (toElement canvas)
        setWidth (floor cw) canvas
        setHeight (floor ch) canvas
        colorTexture <- getCurrentTexture context
        encodeCommands colorTexture
        -- window >>= void <<< requestAnimationFrame (f unit)

    liftEffect render

main :: Effect Unit
main = do
  frameInfo <- create
  errorMessage <- create
  runInBody Deku.do
    D.div_
      [ D.canvas
          Alt.do
            klass_ "absolute w-full h-full"
            D.SelfT !:= gpuMe (errorMessage.push unit) frameInfo.push
          []
      , D.div
          Alt.do
            klass_ "absolute p-3 text-white"
          [ errorMessage.event $> false <|> pure true <#~>
              if _ then
                text (_.avgTime >>> show >>> ("Avg time: " <> _) <$> frameInfo.event)
              else text_ "Your device does not support WebGPU"
          ]
      , D.div
          Alt.do
            id_ "debug-gpu"
          []
      ]