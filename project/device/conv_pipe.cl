/*
 * ------------------------------------------------------
 *
 *   PipeCNN: An OpenCL-Based FPGA Accelerator for CNNs
 *
 * ------------------------------------------------------
 * Filename:
 *   - conv_pipe.cl
 *
 * Author(s):
 *   - Dong Wang, wangdong@m.bjtu.edu.cn
 *
 * History:
 *   - v1.3 Win-Buffer-Based Implementation
 * ------------------------------------
 *
 *   Copyright (C) 2019, Institute of Information Science,
 *   Beijing Jiaotong University. All rights reserved.
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *
 */

#define USE_ROM

// The following macros are used for debug
//#define DEBUG_MEMRD
//#define DEBUG_CONV
//#define DEBUG_BN
//#define DEBUG_POOL
//#define DEBUG_MEMWR
//#define DEBUG_LRN
//#define DEBUG_LRN_OUT

#include "hw_param.cl"
#include "rtl_lib.h"

#pragma OPENCL EXTENSION cl_intel_channels : enable

// Define the precision of the data-path
typedef char DPTYPE;
typedef int  MACTYPE;

// Vectorized data type
typedef struct {
   DPTYPE data[VEC_SIZE];
} lane_data;

// Combined vec-data type from multiple lane
typedef struct {
   lane_data lane[LANE_NUM];
} channel_vec;

// Combined scalar data type from multiple lane
typedef struct {
   DPTYPE lane[LANE_NUM];
} channel_scal;
#ifdef RESNET
typedef struct {
   float lane[LANE_NUM];
} channel_scal_float;
#endif


channel channel_vec    data_ch    __attribute__((depth(0)));
channel channel_vec    weight_ch  __attribute__((depth(0)));
channel channel_scal   bias_ch    __attribute__((depth(8)));
channel channel_scal   conv_ch    __attribute__((depth(CHN_DEPTH)));
channel bool           pool_sync_ch __attribute__((depth(8)));
#ifdef RESNET
channel channel_scal   	batchNorm_ch  __attribute__((depth(CHN_DEPTH)));
channel channel_scal   	bypass_bn_ch  __attribute__((depth(CHN_DEPTH)));
#endif



// parallel MAC units including (VEC_SIZE-1) multipliers
MACTYPE mac(lane_data input, lane_data weights)
{
	MACTYPE output = MASK_MULT & CZERO;

	#pragma unroll
	for(int i=0; i<VEC_SIZE/4; i++){
		//output += input.data[i]*weights.data[i];
		// use packed DSP blocks to improve efficiency
		output += MASK_MULT & mult_add_fix8bx4(input.data[i*4], weights.data[i*4], input.data[i*4+1], weights.data[i*4+1], input.data[i*4+2], weights.data[i*4+2], input.data[i*4+3], weights.data[i*4+3]);
	}
	return output;
}

DPTYPE pool_max(DPTYPE a_in, DPTYPE b_in)
{
	DPTYPE max_value;

	if(a_in >= b_in)
		max_value = a_in;
	else
		max_value = b_in;

	return max_value;

}

// Fetch Data from Global Memory
__kernel
__attribute__((task))
__attribute__((max_global_work_dim(0)))
void memRead(
			// Params Ports
			uchar  data_dim1,
			uchar  data_dim2,
			ushort data_dim1xdim2,
			uchar  weight_dim1,
			uchar  weight_dim2,
			ushort weight_dim3,
			ushort weight_dim4_div_lane, // avoid generating divider
			uchar  weight_dim1x2,
			uint   weight_dim1x2x3,
			uchar  conv_x,
			//uchar  conv_y,           // not used in this version
			uchar  stride,
			uchar  padding,
			uchar  split,
			uchar  group_num_x,
			uchar  group_num_y,
			uchar  group_rem_size_x,
			//uchar  group_rem_size_y, // not used in this version
			uint   group_rem_size_xyz,
			uchar  win_size_x,
			uchar  win_size_y,
			uint   win_size_xyz,
			// Data Ports
			__global lane_data    *restrict bottom,
			__global channel_vec  *restrict weights,
			__global volatile channel_scal *restrict bias        )

{


	// Input Data, Weights and Bias
	lane_data     data_vec;
	channel_vec   data_ch_vec;
	channel_vec   weight_ch_vec;
	channel_scal  bias_ch_in;
	ushort        data_offset = 0; // assuming the 1st layer is not in split

	// virtual loop counters
	ushort gp_num_x, gp_num_y, out_idx_z;
	ushort gp_num_x_winbuf, gp_num_y_winbuf, out_idx_z_winbuf;
	uchar  output_idx_dim1, output_idx_dim2;
	ushort output_idx_dim3;
	uchar  win_itm_x, win_itm_y;
	ushort win_itm_z;

	uchar  gp_item_idx_x;

	ushort feature_idx_dim1, feature_idx_dim2;
	ushort feature_idx_dim3;

	uint   item_loop_bound;

	uchar  flag; // ping-pong flag

	// Ping-pong buffer
	__local lane_data    win_buffer[2][WIN_BUF_SIZE]; // working sequence 0->1->0->1 ...
	// Weight buffer
	__local channel_vec  weight_buffer[WEIGHT_BUF_SIZE];

	// Initialize the winbuf with the data in the first iteration of the group looping (as gp_num_x_winbuf=0, gp_num_y_winbuf=0)
	for(unsigned short win_itm_z=0; win_itm_z<weight_dim3/VEC_SIZE; win_itm_z++){
		for(unsigned char  win_itm_y=0; win_itm_y<win_size_y; win_itm_y++){
			for(unsigned char  win_itm_x=0; win_itm_x<win_size_x; win_itm_x++){

			feature_idx_dim1 = win_itm_x;
			feature_idx_dim2 = win_itm_y;
			feature_idx_dim3 = win_itm_z;

			if((feature_idx_dim1>=padding && feature_idx_dim1<data_dim1+padding) && (feature_idx_dim2>=padding && feature_idx_dim2<data_dim2+padding)){

				data_vec = bottom[data_offset*data_dim1xdim2 + feature_idx_dim3*data_dim1xdim2 + (feature_idx_dim2-padding)*data_dim1 + (feature_idx_dim1-padding)];
			}
			else{
				#pragma unroll
				for(unsigned char vv=0; vv<VEC_SIZE; vv++){
					data_vec.data[vv] = CZERO;
				}
			}

			// start from using buffer[0]
			win_buffer[0][win_itm_z*win_size_y*win_size_x + win_itm_y*win_size_x + win_itm_x] = data_vec;

			}
		}
	}

	if(group_num_x==1 && group_num_y==1){
		gp_num_x_winbuf = 0; // there is only one group for FC mode when batch=1
		gp_num_y_winbuf = 0;}
	else if(group_num_x==1){
		gp_num_x_winbuf = 0; // special case for convolution layers with weight_dim1/2=1, such as resnet50
		gp_num_y_winbuf = 1;}
	else{
		gp_num_x_winbuf = 1; // loop start from the second group for normal convolution layers
		gp_num_y_winbuf = 0;}

	out_idx_z_winbuf = 0;

	// reset global group virtual loop counters
	gp_num_x = 0;
	gp_num_y = 0;
	out_idx_z = 0;

	Group:for(unsigned int out_idx_xyz=0; out_idx_xyz<(weight_dim4_div_lane*group_num_y*group_num_x); out_idx_xyz++){

		// special case when split==1, the output feature maps depend on only half the input feature maps
		if(split==0)
			data_offset = 0;
		else if(out_idx_z_winbuf<(weight_dim4_div_lane>>1)) // the lower half of the output feature maps depend on the lower half of the input
			data_offset = 0;
		else
			data_offset = weight_dim3/VEC_SIZE;	// the upper half of the output feature maps depend on the upper half of the input

				flag = out_idx_xyz & 0x01; //ping-pong flag

				// reset output loop counters
				output_idx_dim1 = 0;
				output_idx_dim2 = 0;
				output_idx_dim3 = 0;
				// reset in-group item counters
				gp_item_idx_x = 0;

				// reset input winbuffer loop counters
				win_itm_x = 0;
				win_itm_y = 0;
				win_itm_z = 0;


				if(gp_num_x==group_num_x-1) // last group in each row
					item_loop_bound = win_size_x>=group_rem_size_x?(win_size_xyz/VEC_SIZE):(group_rem_size_xyz/VEC_SIZE);
				else{
					if(stride>=weight_dim1 || stride>=weight_dim2) // special case convolution layers with stride>weight_dim1/2, such as resnet50
						item_loop_bound = win_size_xyz/VEC_SIZE;
					else
						item_loop_bound = (weight_dim1x2x3*CONV_GP_SIZE_Y*CONV_GP_SIZE_X/VEC_SIZE);
				}

				#pragma ivdep array(win_buffer)
				#pragma ivdep array(weight_buffer)
				Item:for(unsigned int  win_itm_xyz=0; win_itm_xyz<item_loop_bound; win_itm_xyz++){

							// Winbuffer loading operations
							if(win_itm_z<weight_dim3/VEC_SIZE){

								feature_idx_dim1 = win_itm_x+gp_num_x_winbuf*CONV_GP_SIZE_X*stride;
								feature_idx_dim2 = win_itm_y+gp_num_y_winbuf*CONV_GP_SIZE_Y*stride;
								feature_idx_dim3 = win_itm_z;

								if((feature_idx_dim1>=padding && feature_idx_dim1<data_dim1+padding) && (feature_idx_dim2>=padding && feature_idx_dim2<data_dim2+padding)){

									data_vec = bottom[data_offset*data_dim1xdim2 + feature_idx_dim3*data_dim1xdim2 + (feature_idx_dim2-padding)*data_dim1 + (feature_idx_dim1-padding)];
								}
								else{
									#pragma unroll
									for(unsigned char vv=0; vv<VEC_SIZE; vv++){
										data_vec.data[vv] = CZERO;
									}
								}

								win_buffer[(~flag)&0x01][win_itm_z*win_size_y*win_size_x + win_itm_y*win_size_x + win_itm_x] = data_vec;

								// used as loop counters
								if((win_itm_z==weight_dim3/VEC_SIZE-1) && (win_itm_y==win_size_y-1) && (win_itm_x==win_size_x-1))
									win_itm_z = 0;
								else if((win_itm_y==win_size_y-1) && (win_itm_x==win_size_x-1))
									win_itm_z++;

								if((win_itm_y==win_size_y-1) && (win_itm_x==win_size_x-1))
									win_itm_y = 0;
								else if(win_itm_x==win_size_x-1)
									win_itm_y++;

								if(win_itm_x==win_size_x-1)
									win_itm_x = 0;
								else
									win_itm_x++;

							}

							// Load weight into weight buffer
							if(gp_item_idx_x==0){

								weight_ch_vec = weights[out_idx_z*weight_dim1x2x3/VEC_SIZE + output_idx_dim3*weight_dim1x2 + output_idx_dim2*weight_dim1 + output_idx_dim1];
								weight_buffer[output_idx_dim3*weight_dim2*weight_dim1 + output_idx_dim2*weight_dim1 + output_idx_dim1] = weight_ch_vec;

							}

							if(gp_num_x*CONV_GP_SIZE_X+gp_item_idx_x<conv_x){

								if(output_idx_dim1==0 && output_idx_dim2==0 && output_idx_dim3==0){
									bias_ch_in = bias[out_idx_z];
									write_channel_intel(bias_ch, bias_ch_in);
									//#ifdef DEBUG_MEMRD
									//printf("work-item x=%d, y=%d, z=%d, channel =0, write bias=%d\n", output_idx_dim1, output_idx_dim2, output_idx_dim3, bias_ch_in.lane[0]);
									//#endif
								}

								// data
								data_vec = win_buffer[flag][output_idx_dim3*win_size_y*win_size_x + output_idx_dim2*win_size_x + (output_idx_dim1+gp_item_idx_x*stride)];
								#pragma unroll
								for(unsigned char ll=0; ll<LANE_NUM; ll++){
									data_ch_vec.lane[ll] = data_vec;
								}
								write_channel_intel(data_ch, data_ch_vec);


								// weight and bias fetcher
								weight_ch_vec = weight_buffer[output_idx_dim3*weight_dim2*weight_dim1 + output_idx_dim2*weight_dim1 + output_idx_dim1];
								//weight_ch_vec = weights[out_idx_z*weight_dim1x2x3/VEC_SIZE + output_idx_dim3*weight_dim1x2 + output_idx_dim2*weight_dim1 + output_idx_dim1];
								write_channel_intel(weight_ch, weight_ch_vec);

								#ifdef DEBUG_MEMRD
								//if(gp_num_x==group_num_x-1 && gp_num_y==0 && out_idx_z==0){
									//printf("work-item x=%d, y=%d, z=%d, offset=%d, write data in channel 0=%f\n", output_idx_dim1, output_idx_dim2, output_idx_dim3, data_offset, (float)data_ch_vec.lane[0].data[0]);
									printf("work-item x=%d, y=%d, z=%d, write weight in channel 0=%f\n", output_idx_dim1, output_idx_dim2, output_idx_dim3, (float)weight_ch_vec.lane[0].data[0]);
								//}
								#endif

								// used as output loop counters
								if((output_idx_dim3==weight_dim3/VEC_SIZE-1) && (output_idx_dim2==weight_dim2-1) && (output_idx_dim1==weight_dim1-1)){
									output_idx_dim3 = 0;
									gp_item_idx_x++;
								}
								else if((output_idx_dim2==weight_dim2-1)&& (output_idx_dim1==weight_dim1-1))
									output_idx_dim3++;

								if((output_idx_dim2==weight_dim2-1) && (output_idx_dim1==weight_dim1-1))
									output_idx_dim2 = 0;
								else if(output_idx_dim1==weight_dim1-1)
									output_idx_dim2++;

								if(output_idx_dim1==weight_dim1-1)
									output_idx_dim1 = 0;
								else
									output_idx_dim1++;

							}

				}

		// used as virtual group loop counters for winbuf loading operations
		if((out_idx_z_winbuf==weight_dim4_div_lane-1) && (gp_num_y_winbuf==group_num_y-1) && (gp_num_x_winbuf==group_num_x-1))
			out_idx_z_winbuf = 0;
		else if((gp_num_y_winbuf==group_num_y-1) && (gp_num_x_winbuf==group_num_x-1))
			out_idx_z_winbuf++;

		if((gp_num_y_winbuf==group_num_y-1) && (gp_num_x_winbuf==group_num_x-1))
			gp_num_y_winbuf = 0;
		else if(gp_num_x_winbuf==group_num_x-1)
			gp_num_y_winbuf++;

		if(gp_num_x_winbuf==group_num_x-1)
			gp_num_x_winbuf = 0;
		else
			gp_num_x_winbuf++;

		// used as virtual group loop counters
		if((out_idx_z==weight_dim4_div_lane-1) && (gp_num_y==group_num_y-1) && (gp_num_x==group_num_x-1))
			out_idx_z = 0;
		else if((gp_num_y==group_num_y-1) && (gp_num_x==group_num_x-1))
			out_idx_z++;

		if((gp_num_y==group_num_y-1) && (gp_num_x==group_num_x-1))
			gp_num_y = 0;
		else if(gp_num_x==group_num_x-1)
			gp_num_y++;

		if(gp_num_x==group_num_x-1)
			gp_num_x = 0;
		else
			gp_num_x++;


	}

}


__kernel
__attribute__((task))
__attribute__((max_global_work_dim(0)))
void coreConv(
			// Params Ports
			uint  output_num,
			uint  conv_loop_cnt,
			uint  contol, //[0]-> relu  [1]->bypass pooling,for ResNet [0]->bn.[1]->wr(fc)
			char  frac_w,
			char  frac_din,
			char  frac_dout
			)
{
	channel_vec mac_data;
 	channel_vec mac_weight;
	channel_scal bias_ch_out;
	channel_scal conv_ch_in;
	DPTYPE  bias[LANE_NUM];
	MACTYPE conv_out[LANE_NUM];
	MACTYPE lane_accum[LANE_NUM];
	MACTYPE accum_piped[LANE_NUM][PIPE_DEPTH];
	MACTYPE conv_sign_exten[LANE_NUM];
	MACTYPE conv_with_rnd_bit[LANE_NUM];
	MACTYPE conv_sum_bias[LANE_NUM];
	DPTYPE  conv_final[LANE_NUM];

	// each iteration generates one output
	for(unsigned int k=0; k<output_num; k++){

		bias_ch_out = read_channel_intel(bias_ch);

		#pragma unroll
		for(unsigned char ll=0; ll<LANE_NUM; ll++){

			conv_out[ll] = CZERO;
			bias[ll] = bias_ch_out.lane[ll]; // pass to reg, avoid compile error

			#pragma unroll
			for(unsigned int p=0; p<PIPE_DEPTH; p++){
				accum_piped[ll][p] = MASK_ACCUM & CZERO;
			}
		}

		for(int j=0; j<conv_loop_cnt; j++){

			// load data and weights for each lane
			mac_data = read_channel_intel(data_ch);
			mac_weight = read_channel_intel(weight_ch);

			// add results from all lanes
			#pragma unroll
			for(unsigned char ll=0; ll<LANE_NUM; ll++){

				lane_accum[ll] = (MASK_ACCUM & accum_piped[ll][PIPE_DEPTH-1]) + (MASK_MULT & mac(mac_data.lane[ll], mac_weight.lane[ll]));

				// Shift the pipelined registers backwards
				#pragma unroll
				for(unsigned int p=PIPE_DEPTH-1; p>0; p-- ){
					accum_piped[ll][p] = MASK_ACCUM & accum_piped[ll][p-1];
				}

				accum_piped[ll][0] = MASK_ACCUM & lane_accum[ll];

				#ifdef DEBUG_CONV
				//if(ll==0 && k==0){
				//	printf("dot_cnt=%d data=%f weight=%f (loop=%d, lane= %d, vec=0)\n", k, (float)mac_data.lane[ll].data[0], (float)mac_weight.lane[ll].data[0], j, ll);
				//}
				#endif
			}
		}// end of conv loop

		#pragma unroll
		for(unsigned char ll=0; ll<LANE_NUM; ll++){

			// accumulate all the partial results
			#pragma unroll
			for(unsigned i=0; i<PIPE_DEPTH; i++){
				conv_out[ll] += accum_piped[ll][i];
			}

			// note: ((frac_w+frac_din)-frac_dout)) should be checked by host to be a positive number
			if(conv_out[ll]>=0)
				conv_sign_exten[ll] = 0x00;
			else
				conv_sign_exten[ll] = ~(0xFFFFFFFF>>(frac_w+frac_din-frac_dout-1)); // ">>" is logic shift, then perform sign extension manually

			conv_with_rnd_bit[ll] = (conv_sign_exten[ll] | (conv_out[ll]>>(frac_w+frac_din-frac_dout-1))) + 0x01;

			if(conv_with_rnd_bit[ll]>=256)
				conv_sum_bias[ll] = MASK9B & 0xFF; //=255
			else if(conv_with_rnd_bit[ll]<-256)
				conv_sum_bias[ll] = MASK9B & 0x100; //=-256
			else
				conv_sum_bias[ll] = (MASK9B & conv_with_rnd_bit[ll])+(bias[ll]>>(frac_w-frac_dout-1))+0x01;

			// final truncation
			conv_final[ll] = MASK8B & (conv_sum_bias[ll]>>0x01);  // remove the last rounding bit

#ifdef RESNET
			conv_ch_in.lane[ll]= conv_final[ll];
		}
		//BatchNorm
		if(contol==0)
			write_channel_intel(conv_ch, conv_ch_in);
		else//for fc layer no bn,Write
			write_channel_intel(bypass_bn_ch, conv_ch_in);
#else

			// Relu operation
			if((contol&0x01)==0x01){
				if((conv_final[ll]&MASKSIGN)==MASKSIGN) // MSB is sign bit
					conv_ch_in.lane[ll] = 0;
				else
					conv_ch_in.lane[ll] = conv_final[ll];
			}
			else
				conv_ch_in.lane[ll] = conv_final[ll];

			#ifdef DEBUG_CONV
			if(ll==0 && k==0)
				printf("dot_cnt=%d sum=%f rnd=%f sum_bias=%f final=%f (bias=%f)\n\n", k, (float)conv_out[ll], (float)conv_with_rnd_bit[ll], (float)conv_sum_bias[ll], (float)conv_final[ll], (float)bias[ll]);
			#endif

		}

		write_channel_intel(conv_ch, conv_ch_in);
#endif
	}// end of output loop
}
#ifdef RESNET
__kernel
__attribute__((task))
void batchNorm(
				uint dim1xdim2,
				uint input_num,//dim1*dim2*dim3/LANE_NUM
				uint  contol, //[0]-> relu  [1]->bypass pooling
				//char  frac_dout,
				float frac2float,//conv out conver to float
				float frac2char,//bn out conver to char
				__global channel_scal_float *restrict mean,
				__global channel_scal_float *restrict var,
				__global channel_scal_float *restrict alpha,
				__global channel_scal_float *restrict beta)
{
	channel_scal conv_ch_out;
	channel_scal batchNorm_final;
	channel_scal bn_ch_in;
	float bn_in;
	float bn_out;
	float sc_out;
	channel_scal_float mean_ch;
	channel_scal_float var_ch;
	channel_scal_float alpha_ch;
	channel_scal_float beta_ch;

	unsigned int iter=0;
	unsigned int j=dim1xdim2;

	DPTYPE out_final;
	float out_conver;
	for(unsigned int k=0; k<input_num; k++,j++){
		conv_ch_out = read_channel_intel(conv_ch);
		if(j==dim1xdim2)
		{
			mean_ch = mean[iter];
			var_ch = var[iter];
			alpha_ch = alpha[iter];
			beta_ch = beta[iter];
			iter=iter+1;
			j=0;
		}
		
		for(unsigned char ll=0; ll<LANE_NUM;ll++){
			// Input data has "frac_dout" fractional bits
			bn_in = convert_float(conv_ch_out.lane[ll])*frac2float;
			bn_out=(bn_in-mean_ch.lane[ll])*var_ch.lane[ll];
			sc_out=bn_out*alpha_ch.lane[ll]+beta_ch.lane[ll];

			// Convert float to DPTYPE fixed-point
			out_conver=sc_out*frac2char;
			if(out_conver>=0)
				out_conver=out_conver+0.5;
			else
				out_conver=out_conver-0.5;

			if(out_conver>127)
				out_conver=127;
			else if(out_conver<-128)
				out_conver=-128;
			batchNorm_final.lane[ll]=convert_char_rtz(out_conver);//Round towards zero
			// Relu operation
			if((contol&0x01)==0x01){
				if((batchNorm_final.lane[ll]&MASKSIGN)==MASKSIGN) // MSB is sign bit
					bn_ch_in.lane[ll] = 0;
				else
					bn_ch_in.lane[ll] = batchNorm_final.lane[ll];
			}
			else
				bn_ch_in.lane[ll] = batchNorm_final.lane[ll];
#ifdef DEBUG_BN
			printf("ll=%d,conv_ch_out=%d,bn_in=%f,sc_out=%f,batchNorm_final.lane[ll]=%d,bn_ch_in.lane[ll]=%d\n",ll,conv_ch_out.lane[ll],bn_in,sc_out,batchNorm_final.lane[ll],bn_ch_in.lane[ll]);
#endif
		}
		
	write_channel_intel(batchNorm_ch, bn_ch_in);
	}
}
#endif




__kernel
__attribute__((task))
void maxPool(
		// Params Ports
		uchar    conv_x,
		ushort   conv_xy,
		uchar    pool_dim1,
		ushort   pool_dim3,
		ushort   pool_dim1x2,
		uchar    pool_size,
		uchar    pool_stride,
		uchar    padd_offset,
		ushort   pool_times, //pool_group*pool_y
		ushort   pool_group, //the number of pooling z dimension vectorized packet
		ushort   pool_y_bound, //pooling bound per pool_y(item_loop_bound*(pool_win_num_x+1))
		ushort   item_loop_bound, // maximum of load_data_bound and write_back_bound
		ushort   load_data_bound, // pooling window buffer load data bound
		ushort   write_back_bound,// pooling window buffer write back result to global memory bound
		uchar    pool_win_num_x, //the number of pool window buffer
		uchar    win_size_x, // pool window buffer size of x dimension
		__global volatile channel_scal * restrict bottom,
		__global DPTYPE * restrict top
		)
{
	bool  pool_sync=0; // Receive channel synchronization signal
	uint  base_addr; // basic address of global memory
	uchar flag; // ping-pong buffer flag

	// the counter of pooling hierarchy
	ushort  pool_group_cnt; // pooling z dimension vectorized packet counter
	uchar   pool_y_cnt; // pooling y dimension counter
	ushort  item_loop_cnt; // the counter of item_loop_bound
	ushort  pool_win_cnt; // the counter of pool_win_num_x(ping-pong +1)
	// the counter of pool window buffer
	uchar   win_item_x; // x dimension
	uchar   win_item_y; // y dimension
	uchar   win_item_s; // pool stride in pool window buffer
	uchar   win_item_cnt; // for win_item_s
	// the counter of write back
	uchar   gp_final_cnt; // pooling result counter in window buffer
	uchar   lane_cnt;
	ushort  global_z;
	ushort  global_index_z_group;
	uchar   global_index_z_item;
	// the register of pooling
	DPTYPE  shift_reg[LANE_NUM][POOL_MAX_SIZE]; // cache from global memory
	DPTYPE  temp_reg0[LANE_NUM];
	DPTYPE  temp_reg1[LANE_NUM];
	DPTYPE  temp_reg2[LANE_NUM];
	DPTYPE  temp_reg[LANE_NUM];
	DPTYPE  temp_max[LANE_NUM];

	DPTYPE  row_reg0[LANE_NUM][POOL_GP_SIZE_X]; // pooling reslut in the first line
	DPTYPE  row_reg1[LANE_NUM][POOL_GP_SIZE_X]; // pooling reslut in the max(second line , first line)
	DPTYPE  pool_final[2][POOL_GP_SIZE_X][LANE_NUM]; // final pooling reslut

	// init hierarchy counters
	pool_y_cnt = 0;
	pool_group_cnt = 0;
	#pragma ivdep array(pool_final)
	for(ushort i = 0; i < pool_times; i++){
		pool_sync = read_channel_intel(pool_sync_ch);
		mem_fence(CLK_CHANNEL_MEM_FENCE);

		// init counters
		pool_win_cnt = 0;
		item_loop_cnt = 0;
		win_item_x = 0;
		win_item_y = 0;
		win_item_s = 0;
		win_item_cnt = 0;
		gp_final_cnt = 0;
		lane_cnt = 0;

		#pragma ivdep array(pool_final)
		for(ushort k=0; k<pool_y_bound; k++){
			flag = pool_win_cnt & 0x01;
			base_addr = pool_group_cnt*conv_xy + pool_stride*conv_x*pool_y_cnt + pool_stride*pool_win_cnt*POOL_GP_SIZE_X;

			// load data from global memory to shift registers and pool (0--pool_win_num_x-1)
			if((pool_win_cnt < pool_win_num_x)&&(item_loop_cnt < load_data_bound)){

				if(win_item_x > pool_size-1){
					win_item_cnt++;
				}
				#pragma unroll
				for(uchar ll=0; ll<LANE_NUM; ll++){
					if( (pool_win_cnt*POOL_GP_SIZE_X*pool_stride+win_item_x) < conv_x){
						shift_reg[ll][0] = bottom[base_addr+win_item_y*conv_x+win_item_x].lane[ll];

						if((win_item_x == pool_size-1) || (win_item_cnt == pool_stride)){
							temp_reg0[ll] = shift_reg[ll][0];
							temp_reg1[ll] = shift_reg[ll][1];
							temp_reg2[ll] = shift_reg[ll][2];
						}

						else{
							temp_reg0[ll] = CZERO;
							temp_reg1[ll] = CZERO;
							temp_reg2[ll] = CZERO;
						}
						if(pool_size == 3){
							temp_reg[ll] = pool_max(temp_reg0[ll],temp_reg1[ll]);
							temp_max[ll] = pool_max(temp_reg2[ll],temp_reg[ll]);
							if(win_item_y == 0){
								row_reg0[ll][win_item_s] = temp_max[ll];
							}
							else if(win_item_y == 1){
								row_reg1[ll][win_item_s] = pool_max(temp_max[ll],row_reg0[ll][win_item_s]);
							}
							else{
								pool_final[flag][win_item_s][ll] = pool_max(temp_max[ll],row_reg1[ll][win_item_s]);
							}
						}
						else{
							temp_max[ll] = pool_max(temp_reg1[ll],temp_reg0[ll]);
							if(win_item_y == 0){
								row_reg0[ll][win_item_s] = temp_max[ll];
							}
							else{
								pool_final[flag][win_item_s][ll] = pool_max(temp_max[ll],row_reg0[ll][win_item_s]);
							}
						}

						// shift register
						#pragma unroll
						for(uchar p=POOL_MAX_SIZE-1; p>0; p--){
							shift_reg[ll][p] = shift_reg[ll][p-1];
						}
					}
				}


				if((win_item_x == pool_size-1)||(win_item_cnt == pool_stride)){
					win_item_s++;
				}

				if(win_item_cnt == pool_stride){
					win_item_cnt = 0;
				}

				if((win_item_y == pool_size-1) && (win_item_x == win_size_x-1))
					win_item_y = 0;
				else if(win_item_x == win_size_x-1)
					win_item_y++;
				if(win_item_x == win_size_x-1)
					win_item_x = 0;
				else
					win_item_x++;

				if(win_item_x == 0)
					win_item_s = 0;

			}

			if((pool_win_cnt > 0) && (item_loop_cnt < write_back_bound)){
				if(((pool_win_cnt-1)*POOL_GP_SIZE_X+gp_final_cnt) < pool_dim1){
					global_z = pool_group_cnt*LANE_NUM+lane_cnt;
					global_index_z_group = (global_z-padd_offset) / VEC_SIZE;
					global_index_z_item =  (global_z-padd_offset) % VEC_SIZE;
					if((global_z-padd_offset)<pool_dim3 && global_z>=padd_offset){
						top[global_index_z_group*pool_dim1x2*VEC_SIZE+pool_y_cnt*pool_dim1*VEC_SIZE+((pool_win_cnt-1)*POOL_GP_SIZE_X+gp_final_cnt)*VEC_SIZE+global_index_z_item] = pool_final[!flag][gp_final_cnt][lane_cnt];
					}
				}

				if((gp_final_cnt == POOL_GP_SIZE_X-1) && (lane_cnt == LANE_NUM-1))
					gp_final_cnt = 0;
				else if(lane_cnt == LANE_NUM-1)
					gp_final_cnt++;
				if(lane_cnt == LANE_NUM-1)
					lane_cnt = 0;
				else
					lane_cnt++;
			}

			if((pool_win_cnt == pool_win_num_x) && (item_loop_cnt == item_loop_bound-1))
				pool_win_cnt = 0;
			else if(item_loop_cnt == item_loop_bound-1)
				pool_win_cnt++;
			if(item_loop_cnt == item_loop_bound-1)
				item_loop_cnt = 0;
			else
				item_loop_cnt++;
		}

		if((pool_group_cnt == pool_group-1) && (pool_y_cnt == pool_dim1-1))
			pool_group_cnt = 0;
		else if(pool_y_cnt == pool_dim1-1)
			pool_group_cnt++;
		if(pool_y_cnt == pool_dim1-1)
			pool_y_cnt = 0;
		else
			pool_y_cnt++;
	}
}

// Store Data to Global Memory
__kernel
__attribute__((reqd_work_group_size(1,1,LANE_NUM)))
void memWrite(
				// Params Ports
				uchar  out_dim1,
				uchar  out_dim2,
				ushort out_dim3,
				ushort out_dim1xbatch, // out_dim1 x sqrt(batch_size)
				uint   out_dim1x2xbatch, // out_dim1 x out_dim2 x batch_size
				uchar  batch_indx_dim1,
				uchar  batch_indx_dim2,
#ifdef RESNET
				uchar  bypass,
				uchar  pool_pad,	  //RESNET need pad,set to 1,other CNN set 0
#endif
				uchar  padd_offset,
				uchar  pool_on,
				uchar  pool_size,
				uchar  pool_stride,
				// Data Ports
				__global DPTYPE *restrict top
				)
{
	uchar  global_x = get_global_id(0); // max value 256
	uchar  global_y = get_global_id(1); // max value 256
	ushort global_z = get_global_id(2); // max value 4096
	uchar  local_x 	= get_local_id(0); // max value 256
	uchar  local_y 	= get_local_id(1); // max value 256
	uchar  local_z 	= get_local_id(2); // max value 256
	ushort group_z  = get_group_id(2);

	uchar  index_z_item; // max value 256
	ushort index_z_group;// max value 4096
	uint   top_addr;
	bool pool_on_signal=1;
	channel_scal   output;
	__local DPTYPE buffer[LANE_NUM];

	// use the first local work-item to read the vectorized output data from channel
	if(local_z==0){
#ifdef RESNET
    if(bypass==0){//bypass==0,bn
      // for ResNet padding
      if((pool_on == 1) && ((global_y >= out_dim2-pool_pad) || ((global_x >= out_dim1-pool_pad)))){
        #pragma unroll
    		for(uchar ll=0; ll<LANE_NUM; ll++){
    			output.lane[ll]=CZERO;
    		}
      }
      else{
        output = read_channel_intel(batchNorm_ch);
      }
    }
    else // bypass == 1 bypass_bn_ch
      output = read_channel_intel(bypass_bn_ch);

#else
		output = read_channel_intel(conv_ch);
#endif

		// store the vectorized output into local buffer
		#pragma unroll
		for(uchar ll=0; ll<LANE_NUM; ll++){
			buffer[ll]=output.lane[ll];
		}
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	if(pool_on == 1){
		top_addr = group_z*out_dim1x2xbatch*LANE_NUM +(global_y+batch_indx_dim2*out_dim2)*out_dim1xbatch*LANE_NUM + (global_x+batch_indx_dim1*out_dim1)*LANE_NUM + local_z;
	}
	else{
		index_z_group = (global_z-padd_offset)/VEC_SIZE;
		index_z_item  = (global_z-padd_offset)%VEC_SIZE;
		top_addr = index_z_group*out_dim1x2xbatch*VEC_SIZE + (global_y+batch_indx_dim2*out_dim2)*out_dim1xbatch*VEC_SIZE + (global_x+batch_indx_dim1*out_dim1)*VEC_SIZE + index_z_item;
	}

	if((global_z-padd_offset)<out_dim3 && (global_z>=padd_offset)){

		top[top_addr] = buffer[local_z];

		#ifdef DEBUG_MEMWR
		//if((global_z-padd_offset) == 0){
			//for(unsigned char ll=0; ll<LANE_NUM; ll++){
			printf("MemWr results= %f (x=%d, y=%d, z=%d, ll=%d)\n", (float)output.lane[0], global_x, global_y, global_z, 0);
			//}
		//	}
		#endif

	}

	barrier(CLK_LOCAL_MEM_FENCE | CLK_CHANNEL_MEM_FENCE);

	if(pool_on == 1){
		if((global_x==out_dim1-1)&&(global_y > 0)&&((global_y-pool_size+1)%2 == 0)&&(local_z ==LANE_NUM-1)){
			write_channel_intel(pool_sync_ch, pool_on_signal);
		}
	}

}
#ifdef RESNET
__kernel
__attribute__((task))
void eltwise(
			uint  input_num,//dim1*dim2*dim3/VEC_SIZE
			uchar pool_on,//only avgpool used
			//uchar pool_size,  // by now, only pooling size is 7
			uchar  conv_x,
			uint  conv_xy,
			uchar  stride,
			float divisor,	  //1/pool_size^2
			float in1_frac,
			float in2_frac,//conver the input frac to output frac
			// float out_conver2char,
			__global lane_data *restrict bottom_1,
			__global lane_data *restrict bottom_2,
			__global lane_data *restrict top
			)
{
	lane_data data_out;
	float sum;
	// float sum[VEC_SIZE];
	float sumAvg[VEC_SIZE];
	float out;
	//uchar pool_size_num;  //pool_size^2
	//pool_size_num=pool_size*pool_size;
	uchar conv_itm_x=0;
	uint  conv_itm_xyz=0;
	uint xyz_offset=0;
	uint xy_offset=0;
	uint ptr=0;
	uint outnum=0;//if have avgpool the out ptr
	float avgPoolSum[VEC_SIZE];
	float avgPoolBuf[VEC_SIZE][ELT_PIPE_DEPTH];
	#pragma unroll
	for(unsigned char vv=0; vv<VEC_SIZE; vv++){
		avgPoolSum[vv]=0;
		#pragma unroll
		for(unsigned char pp=0; pp<ELT_PIPE_DEPTH; pp++){
			avgPoolBuf[vv][pp]=0;
		}
	}

	for(unsigned int j=0;j<input_num;j++)
	{
		#pragma unroll
		for(unsigned char vv=0; vv<VEC_SIZE; vv++){
			sum=bottom_1[j].data[vv]*in1_frac+bottom_2[j].data[vv]*in2_frac;
			// relu
			if(sum<0)
				sum=0;
			if(pool_on!=3){
				sum=sum+0.5;
				// //overflow
				if(sum>127)
					sum=127;
				data_out.data[vv]=convert_char_rtz(sum);//Round towards zero
			}
			else{
				sumAvg[vv]=sum+avgPoolBuf[vv][ELT_PIPE_DEPTH-1];
				#pragma unroll
				for(uchar p=ELT_PIPE_DEPTH-1; p>0; p-- ){
					avgPoolBuf[vv][p] = avgPoolBuf[vv][p-1];
				}
				avgPoolBuf[vv][0]=sumAvg[vv];
			}

		}
		if(pool_on==0){
			top[j]=data_out;
		}
		else if(pool_on==2){//stride pool
			conv_itm_xyz=xyz_offset+xy_offset+conv_itm_x;
			if(conv_itm_xyz==j){
				top[outnum]=data_out;
				outnum++;
				conv_itm_x=conv_itm_x+stride;
				if(conv_itm_x>=conv_x){
					conv_itm_x=0;
					xy_offset+=stride*conv_x;
					if(xy_offset>=conv_xy){
						xy_offset=0;
						xyz_offset+=conv_xy;
					}
				}
			}

		}
		else if(pool_on==3){//avgpool
			ptr=ptr+1;
			if(ptr==AVGPOOL_SIZE)
			{
				ptr=0;
				#pragma unroll
				for(unsigned char vv=0; vv<VEC_SIZE; vv++){
					#pragma unroll
					for(unsigned i=0; i<ELT_PIPE_DEPTH; i++){
						avgPoolSum[vv] += avgPoolBuf[vv][i];
						avgPoolBuf[vv][i]=0;
					}
					out=avgPoolSum[vv]*divisor+0.5;
					//overflow,because of relu no <0 value here
					if(out>127)
						out=127;
					data_out.data[vv]=convert_char_rtz(out);//	Round towards zero
					avgPoolSum[vv]=0;
				}
				top[outnum]=data_out;
				outnum++;
			}
		}

	}
}

#endif

__kernel
__attribute__((max_work_group_size(LRN_MAX_LOCAL_SIZE)))
void lrn(
			// Params Ports
			uchar data_dim1,
			uchar data_dim2,
			char  frac_dout,
			// Data Ports
			__global lane_data *restrict bottom,
			__global lane_data *restrict top
		)
{
	uchar  global_x = get_global_id(0); // max value 256
	uchar  global_y = get_global_id(1); // max value 256
	ushort global_z = get_global_id(2); // max value 4096

	#ifdef DEBUG_LRN
	int local_x = get_local_id(0);
	int local_y = get_local_id(1);
	int local_z = get_local_id(2);
	int block_x = get_group_id(0);
	int block_y = get_group_id(1);
	int block_z = get_group_id(2);
	#endif

	__local DPTYPE z_buffer[VEC_SIZE*LRN_MAX_LOCAL_SIZE+LRN_WIN_SIZE]; // allocate two more points for padding
	__local DPTYPE lrn_buffer[VEC_SIZE*LRN_MAX_LOCAL_SIZE];
	channel_scal data_in;
	channel_scal data_pad_left;
	channel_scal data_pad_right;
	channel_scal data_out;
	lane_data    data_in_partial;
	lane_data    data_left_partial;
	lane_data    data_right_partial;
	lane_data    data_out_partial;
	int          *convert_ptr;
	int          expo;
	uint         manti;
	uint         addr_1, addr_2, addr;
	float        lrn_reg1, lrn_reg2, lrn_tmp, lrn_out;
	short        lrn_cnvt, lrn_cnvt2;

	// Load the all data in one line along dim3 into local line buffer
	#pragma unroll
	for(unsigned char ll=0; ll<VEC_SIZE; ll++){
		z_buffer[global_z*VEC_SIZE+ll+LRN_WIN_SIZE/2] = bottom[global_z*data_dim2*data_dim1 + global_y*data_dim1+ global_x].data[ll];
	}

	//Padding left
	if(global_z==0){
		#pragma unroll
		for(unsigned char ll=0; ll<LRN_WIN_SIZE/2; ll++){
			z_buffer[ll] = CZERO;
		}
	}

	// Padding right
	if(global_z==(get_global_size(2)-1)){
		#pragma unroll
		for(unsigned char ll=0; ll<LRN_WIN_SIZE/2; ll++){
			z_buffer[VEC_SIZE*get_local_size(2)+ll+LRN_WIN_SIZE/2] = CZERO;
		}
	}

	#ifdef DEBUG_LRN
	if(global_z==0&&global_x==0&&global_y==0)
	printf("Kernel LRN: work-item x=%d, y=%d, z=%d(z_local=%d)\n", global_x, global_y, global_z, local_z);
	#endif
	barrier(CLK_LOCAL_MEM_FENCE); // fill all values of the line bufer before reading it

	// Piecewise interpolation pipeline for lrn operation (i.e., y=pwlf(x'))
	for(unsigned char ll=0; ll<VEC_SIZE; ll++){
		lrn_reg2 = CZERO;
		#pragma unroll
		for(char k=-LRN_WIN_SIZE/2; k<=LRN_WIN_SIZE/2; k++){
			lrn_cnvt = z_buffer[global_z*VEC_SIZE+ll+k+LRN_WIN_SIZE/2]<<(-frac_dout);
			lrn_reg1 = convert_float(lrn_cnvt);
			lrn_reg2 += lrn_reg1 * lrn_reg1;
			#ifdef DEBUG_LRN
			if(global_z==0&&global_x==0&&global_y==0)
			printf("x=%f(k=%d), ", lrn_reg1, k);
			#endif
		}
		convert_ptr = (int*) (&lrn_reg2);
		expo = (EXP_MASK & (*convert_ptr >> MAN_BITS)) - 127;
		manti = ((*convert_ptr) & MAN_MASK); //does not include the implicit 1

		addr_1 = ((expo-EXP_STEP_MIN)>>EXP_STEP_LOG)<<MAN_INDEX_BITS;
		addr_2 = (manti>>(MAN_BITS-MAN_INDEX_BITS) & MAN_INDEX_MASK)+1;
		if(expo<EXP_STEP_MIN)
			addr = 0; // use the first segment
		else
			addr = addr_1+addr_2;

		lrn_tmp = ((lrn_reg2-x_sample[addr])*h_inv[addr])*coef1[addr] + coef0[addr];

		lrn_cnvt2 = z_buffer[global_z*VEC_SIZE+ll+LRN_WIN_SIZE/2]<<(-frac_dout);
		lrn_out = lrn_tmp*convert_float(lrn_cnvt2);

		lrn_buffer[global_z*VEC_SIZE+ll] = convert_char_rte(lrn_out);

		#ifdef DEBUG_LRN
		if(global_z==0&&global_x==0&&global_y==0)
		printf("\nKernel LRN (ll=%d): pwlf_x=%f, expo=%d, addr=%d, pwlf_y=%f, lrn=%f\n", ll, lrn_reg2, expo, addr, lrn_tmp, lrn_out);
		#endif
		barrier(CLK_LOCAL_MEM_FENCE);
	}

	// Store the results back to global mem
	#pragma unroll
	for(unsigned char vv=0; vv<VEC_SIZE; vv++){
		data_out_partial.data[vv]=lrn_buffer[global_z*VEC_SIZE+vv];
	}
	top[global_z*data_dim2*data_dim1 + global_y*data_dim1 + global_x] = data_out_partial;

	#ifdef DEBUG_LRN_OUT
	if(global_z==0&&global_x==0&&global_y==0)
	printf("\nKernel LRN OUT: x=%d, y=%d, z=%d, result=%f\n", global_x, global_y, global_z, (float)data_out_partial.data[0]);
	#endif

}
